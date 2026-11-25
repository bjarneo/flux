using System.Text.Json.Nodes;

namespace FluxKit;

// 1 key binding of Hyprland on the computer. Ref runs it, and Keys is its
// combination, such as "SUPER SHIFT RETURN".
public sealed record DesktopShortcut(string Ref, string Keys, string Description)
{
    public string Id => Ref;
}

// 1 workspace of the computer with its number of windows.
public sealed record DesktopWorkspace(int Id, int Windows);

// 1 window of the computer. Address focuses it, App is the name of its app,
// and Focused is true for the window that has the focus.
public sealed record DesktopWindow(string Address, int Workspace, string App, string WindowClass, string Title, bool Focused)
{
    public string Id => Address;
}

// The key bindings and the workspaces of a computer, for the Omarchy
// panel. Loaded is false until the first answer.
public sealed record DesktopShortcutsState
{
    public ValueList<DesktopShortcut> Shortcuts { get; init; } = ValueList<DesktopShortcut>.Empty;
    public ValueList<DesktopWorkspace> Workspaces { get; init; } = ValueList<DesktopWorkspace>.Empty;
    public int Active { get; init; }
    public string? Error { get; init; }
    public bool Loaded { get; init; }

    // The windows of all workspaces, or null when the computer does not send
    // them.
    public ValueList<DesktopWindow>? Windows { get; init; }

    // The windows of the active workspace.
    public IReadOnlyList<DesktopWindow> ActiveWindows => (Windows ?? ValueList<DesktopWindow>.Empty).Where(w => w.Workspace == Active).ToArray();

    // The number of windows on the active workspace: from the window list
    // when the computer sends it, else from the workspace list.
    public int ActiveWindowCount =>
        Windows is not null ? ActiveWindows.Count : Workspaces.FirstOrDefault(w => w.Id == Active)?.Windows ?? 0;
}

// The window actions of the Omarchy panel.
public enum DesktopAction
{
    Close,
    Fullscreen,
    Float,
    Split,
    Scratchpad,
    NextWindow,
    NextWorkspace,
    PreviousWorkspace,
}

// The directions of focus and swap.
public enum DesktopDirection
{
    Left,
    Up,
    Down,
    Right,
}

// flux.shortcuts: this computer moves around Omarchy. The Omarchy computer
// sends its key bindings, workspaces, and windows, and it runs a binding or
// an action. It needs remote_input on the computer. Shortcuts.swift of the
// Mac app has the same rules.
public static class DesktopShortcuts
{
    // The highest workspace that this computer can select.
    public const int MaxWorkspace = 10;

    // How often the Omarchy panel reads the workspaces again.
    public static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(3);

    // The shortcuts that the Omarchy panel pins until the user pins others.
    public static readonly IReadOnlyList<string> DefaultPins = ["Omarchy menu", "Apps menu", "Terminal", "Browser", "File manager", "Screenshot"];

    // Asks for the key bindings and the workspaces.
    public static Packet Request() => new(PacketType.Shortcuts, new JsonObject { ["request"] = true });

    // Asks for the workspaces only.
    public static Packet Refresh() => new(PacketType.Shortcuts);

    public static Packet Run(DesktopShortcut s) => new(PacketType.Shortcuts, new JsonObject { ["run"] = s.Ref });

    public static Packet Action(DesktopAction a) => new(PacketType.Shortcuts, new JsonObject { ["action"] = ActionName(a) });

    public static Packet Workspace(int id) =>
        new(PacketType.Shortcuts, new JsonObject { ["action"] = "workspace", ["workspace"] = id });

    public static Packet MoveToWorkspace(int id) =>
        new(PacketType.Shortcuts, new JsonObject { ["action"] = "moveToWorkspace", ["workspace"] = id });

    public static Packet Focus(DesktopDirection d) =>
        new(PacketType.Shortcuts, new JsonObject { ["action"] = "focus", ["direction"] = DirectionName(d) });

    public static Packet Swap(DesktopDirection d) =>
        new(PacketType.Shortcuts, new JsonObject { ["action"] = "swap", ["direction"] = DirectionName(d) });

    // Focuses the window at address. The computer answers with the windows
    // again.
    public static Packet FocusWindow(string address) =>
        new(PacketType.Shortcuts, new JsonObject { ["action"] = "focusWindow", ["address"] = address });

    // The name of an action on the wire.
    public static string ActionName(DesktopAction a) => a switch
    {
        DesktopAction.Close => "close",
        DesktopAction.Fullscreen => "fullscreen",
        DesktopAction.Float => "float",
        DesktopAction.Split => "split",
        DesktopAction.Scratchpad => "scratchpad",
        DesktopAction.NextWindow => "nextWindow",
        DesktopAction.NextWorkspace => "nextWorkspace",
        _ => "previousWorkspace",
    };

    // The name of a direction on the wire.
    public static string DirectionName(DesktopDirection d) => d switch
    {
        DesktopDirection.Left => "l",
        DesktopDirection.Up => "u",
        DesktopDirection.Down => "d",
        _ => "r",
    };

    // The workspace action for a digit with super, as the Omarchy bindings
    // do: super and a digit selects the workspace, and super, shift, and a
    // digit moves the window there. 0 is workspace 10. It returns null for
    // other keys. Omarchy binds these to key codes, which the keys from this
    // computer cannot press, so the computer runs the action instead.
    public static Packet? ForDigit(string text, RemoteMods mods)
    {
        if (text.Length != 1 || text[0] is < '0' or > '9')
        {
            return null;
        }
        if (!mods.Super || mods.Ctrl || mods.Alt)
        {
            return null;
        }
        var digit = text[0] - '0';
        var id = digit == 0 ? MaxWorkspace : digit;
        return mods.Shift ? MoveToWorkspace(id) : Workspace(id);
    }

    // Returns the state after an answer. An answer without the list or the
    // windows keeps them from old. An error keeps the rest of old.
    public static DesktopShortcutsState Merge(DesktopShortcutsState? old, Packet p)
    {
        var s = (old ?? new DesktopShortcutsState()) with { Loaded = true };
        if (p.String("error") is { Length: > 0 } error)
        {
            return s with { Error = error };
        }
        if (p.Array("shortcuts") is { } shortcuts)
        {
            var list = new List<DesktopShortcut>();
            foreach (var e in shortcuts.OfType<JsonObject>())
            {
                if (Json.String(e["ref"]) is { } reference && Json.String(e["description"]) is { } description)
                {
                    list.Add(new DesktopShortcut(reference, Json.String(e["keys"]) ?? "", description));
                }
            }
            s = s with { Shortcuts = ValueList.From(list) };
        }
        if (p.Array("workspaces") is { } workspaces)
        {
            var list = new List<DesktopWorkspace>();
            foreach (var e in workspaces.OfType<JsonObject>())
            {
                if (Json.Int(e["id"]) is { } id)
                {
                    list.Add(new DesktopWorkspace(id, Json.Int(e["windows"]) ?? 0));
                }
            }
            s = s with { Workspaces = ValueList.From(list) };
        }
        if (p.Array("windows") is { } windows)
        {
            var list = new List<DesktopWindow>();
            foreach (var e in windows.OfType<JsonObject>())
            {
                if (Json.String(e["address"]) is not { Length: > 0 } address || Json.Int(e["workspace"]) is not { } workspace)
                {
                    continue;
                }
                var windowClass = Json.String(e["class"]) ?? "";
                var app = Json.String(e["app"]) ?? "";
                list.Add(new DesktopWindow(address, workspace, app.Length == 0 ? windowClass : app, windowClass,
                    Json.String(e["title"]) ?? "", Json.Bool(e["focused"]) ?? false));
            }
            s = s with { Windows = ValueList.From(list) };
        }
        if (p.Int("active") is { } active)
        {
            s = s with { Active = active };
        }
        return s with { Error = null };
    }

    // The shortcuts that the panel pins, in the order of pins.
    public static IReadOnlyList<DesktopShortcut> Pinned(IReadOnlyList<DesktopShortcut> all, IReadOnlyList<string> pins) =>
        pins.Select(name => all.FirstOrDefault(s => s.Description == name)).OfType<DesktopShortcut>().ToArray();

    // The shortcuts that match each word of query in the description or the
    // keys.
    public static IReadOnlyList<DesktopShortcut> Search(IReadOnlyList<DesktopShortcut> all, string query)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0)
        {
            return all;
        }
        return all.Where(s =>
        {
            var text = (s.Description + " " + s.Keys).ToLowerInvariant();
            return words.All(w => text.Contains(w, StringComparison.Ordinal));
        }).ToArray();
    }

    // The keys of a shortcut for a label, such as "super shift return".
    public static string KeysLabel(string keys) => keys.ToLowerInvariant();
}
