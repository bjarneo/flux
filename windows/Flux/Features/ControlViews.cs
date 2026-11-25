using System.Windows;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The tools of Control for the Omarchy panel, the remote desktop, and the
// touchpad, with their lines, the tray actions, Get files in the chat, and
// the setting "Alt is Alt". ControlView.swift and the menu items of the
// Mac app have the same rules. A tool shows while a paired computer in
// scope has the feature, and it is on while an online computer in scope
// can run it.
public static class ControlViews
{
    // The settings key of the Alt setting. RemoteKeyTarget uses the same key.
    const string AltIsAltKey = "input.altIsAlt";

    static RemoteInputPlugin? Input(AppModel m) => m.Core.Plugin<RemoteInputPlugin>();

    // True when the computer can show its screen now.
    static bool CanShowScreen(AppModel m, DeviceSnapshot d) => DesktopPlugin.Supported(d) && Input(m)?.Model.IsDesktopOn(d.Id) == true;

    // True when the computer can run the Omarchy panel now: it shows its
    // screen, it takes remote input, and it runs flux.shortcuts.
    static bool CanRunPanel(AppModel m, DeviceSnapshot d) =>
        CanShowScreen(m, d) && DesktopPlugin.ShortcutsSupported(d) && Input(m)?.Model.IsOn(d.Id) == true;

    // True when the computer takes remote input now.
    static bool CanTakeInput(AppModel m, DeviceSnapshot d) => RemoteInputPlugin.Supported(d) && Input(m)?.Model.IsOn(d.Id) == true;

    // The online computers in scope for which can is true.
    static DeviceSnapshot[] Ready(AppModel m, Func<DeviceSnapshot, bool> can) =>
        m.ConnectedPaired.Where(d => (m.Scope is null || d.Id == m.Scope) && can(d)).ToArray();

    // True when a paired computer in scope has the feature, also while it is
    // not reachable.
    static bool Has(AppModel m, Func<DeviceSnapshot, bool> feature) =>
        m.Paired.Any(d => (m.Scope is null || d.Id == m.Scope) && feature(d));

    // Control

    public static UIElement? OmarchyTool(AppModel m)
    {
        if (Input(m) is null || m.Core.Plugin<DesktopPlugin>() is null || !Has(m, d => DesktopPlugin.Supported(d) && DesktopPlugin.ShortcutsSupported(d)))
        {
            return null;
        }
        // The panel shows at the side of the screen of the computer.
        return Parts.GridTool(Icons.Grid, "Omarchy panel", OmarchyLine(m),
            () => Run(m, d => CanRunPanel(m, d), "Open the Omarchy panel of", d => DesktopWindows.Show(m, d, DesktopPanel.Omarchy)),
            Ready(m, d => CanRunPanel(m, d)).Length > 0);
    }

    public static UIElement? DesktopTool(AppModel m)
    {
        if (Input(m) is null || m.Core.Plugin<DesktopPlugin>() is null || !Has(m, DesktopPlugin.Supported))
        {
            return null;
        }
        return Parts.GridTool(Icons.Desktop, "Remote desktop", DesktopLine(m),
            () => Run(m, d => CanShowScreen(m, d), "Show the screen of", d => DesktopWindows.Show(m, d)),
            Ready(m, d => CanShowScreen(m, d)).Length > 0);
    }

    public static UIElement? TouchpadTool(AppModel m)
    {
        if (Input(m) is null || !Has(m, RemoteInputPlugin.Supported))
        {
            return null;
        }
        return Parts.GridTool(Icons.Mouse, "Touchpad", OffLine(m, d => CanTakeInput(m, d), RemoteInputPlugin.Supported) ?? "Pointer, keys, and slides",
            () => Run(m, d => CanTakeInput(m, d), "Control the pointer of", d => TouchpadWindows.Show(m, d)),
            Ready(m, d => CanTakeInput(m, d)).Length > 0);
    }

    // "Off on <computer>" when the 1 online computer in scope that has the
    // feature turned it off, else null.
    public static string? OffLine(AppModel m, Func<DeviceSnapshot, bool> can, Func<DeviceSnapshot, bool> supported)
    {
        if (Ready(m, can).Length > 0)
        {
            return null;
        }
        var off = Ready(m, supported);
        return off.Length == 1 ? $"Off on {off[0].Name}" : null;
    }

    // The line of the remote desktop: off, view only, or the default line.
    public static string DesktopLine(AppModel m)
    {
        if (OffLine(m, d => CanShowScreen(m, d), DesktopPlugin.Supported) is { } off)
        {
            return off;
        }
        if (Ready(m, d => CanShowScreen(m, d)) is [var d] && Input(m)?.Model.IsOn(d.Id) != true)
        {
            return "View only";
        }
        return "See and use the screen";
    }

    // "Workspace 2 · 3 windows" of the computer in scope while the panel
    // knows it, else the default line.
    public static string OmarchyLine(AppModel m)
    {
        if (m.Scope is not { } id || m.Core.Plugin<DesktopPlugin>()?.Model.ShortcutsOf(id) is not { Loaded: true, Active: > 0 } s)
        {
            return "Workspaces, windows, and key bindings";
        }
        var n = s.ActiveWindowCount;
        return $"Workspace {s.Active} · {n} {(n == 1 ? "window" : "windows")}";
    }

    // Runs the action on the only computer that can take it, or asks which
    // computer. title tells the action, such as "Show the screen of".
    public static void Run(AppModel m, Func<DeviceSnapshot, bool> can, string title, Action<DeviceSnapshot> action)
    {
        var ready = Ready(m, can);
        switch (ready.Length)
        {
            case 0:
                m.Show(m.Scope is null ? "No computer is connected" : $"{Shared.ScopeName(m)} is not reachable");
                break;
            case 1:
                action(ready[0]);
                break;
            default:
                if (Choose(title, ready) is { } d)
                {
                    action(d);
                }
                break;
        }
    }

    // Asks which computer takes the action.
    static DeviceSnapshot? Choose(string title, IReadOnlyList<DeviceSnapshot> devices)
    {
        var tn = Tn.Current;
        DeviceSnapshot? chosen = null;
        Window? w = null;
        var rows = devices.Select(d => (UIElement)new PlainButton(Ui.Tile(Ui.H(10,
                Ui.Icon(Texts.Symbol(d), 15, tn.Accent), Ui.Text(d.Name, 13, FontWeights.SemiBold).Fill()), padding: 10), () =>
            {
                chosen = d;
                w!.Close();
            }).Named(d.Name)).ToList();
        var cancel = new FluxButton("Cancel", ButtonKind.Outlined, () => w!.Close()).Align(HorizontalAlignment.Right, VerticalAlignment.Center);
        var body = Ui.V(Metrics.Gap, new UIElement[] { Ui.Text($"{title}…", 17, FontWeights.SemiBold, wrap: true) }.Concat(rows).Append(cancel));
        w = new Window
        {
            Title = title,
            Owner = Application.Current?.Windows.OfType<Window>().FirstOrDefault(x => x.IsActive),
            Width = 340,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = tn.TileHi,
            FontFamily = Faces.Body,
            Content = Ui.Box(body, 20, 18, 20, 18),
        };
        w.InputBindings.Add(new KeyBinding(new Relay(w.Close), Key.Escape, ModifierKeys.None));
        w.ShowDialog();
        return chosen;
    }

    // Chat

    // Get files in the tray of the chat of a computer: the home folder of
    // the computer, read-only.
    public static (string Title, string Glyph, Action Run)? GetFilesTool(AppModel m, DeviceSnapshot d) =>
        m.Core.Plugin<BrowsePlugin>() is null || !d.Accepts(PacketType.SftpRequest) ? null : ("Get files", Icons.Folder, () => BrowseWindows.Show(m, d.Id));

    // Tray

    public static (string Title, Action Run)? TouchpadAction(AppModel m, DeviceSnapshot d) =>
        Input(m) is not null && CanTakeInput(m, d) ? ("Touchpad and Keyboard…", () => TouchpadWindows.Show(m, d)) : null;

    public static (string Title, Action Run)? DesktopAction(AppModel m, DeviceSnapshot d) =>
        m.Core.Plugin<DesktopPlugin>() is not null && CanShowScreen(m, d) ? ("Remote Desktop…", () => DesktopWindows.Show(m, d)) : null;

    public static (string Title, Action Run)? BrowseAction(AppModel m, DeviceSnapshot d) =>
        m.Core.Plugin<BrowsePlugin>() is not null && d.Accepts(PacketType.SftpRequest) ? ("Browse Files…", () => BrowseWindows.Show(m, d.Id)) : null;

    // Settings

    // The setting "Alt is Alt" of the touchpad and the remote desktop. The
    // key rows of both windows have it too.
    public static (string Label, UIElement Content)? Settings(AppModel m)
    {
        if (Input(m) is null)
        {
            return null;
        }
        var settings = m.Core.Settings;
        return ("Touchpad and remote desktop", SettingsView.Group(
            SettingsView.Toggle("Alt is Alt", settings.Bool(AltIsAltKey, false), on =>
            {
                settings.Set(AltIsAltKey, on);
                foreach (var w in TouchpadWindows.All)
                {
                    w.Controller.AltIsAlt = on;
                }
                if (DesktopWindows.Current is { } desktop)
                {
                    desktop.Controller.AltIsAlt = on;
                }
            }),
            SettingsView.Note("On, Alt with a letter is a shortcut on the computer. Off, AltGr types the characters of the layout of this computer, such as @ on a Nordic keyboard."),
            SettingsView.Note("The touchpad, the remote desktop, and the answers to agents ask for Windows Hello first. A check stays valid for 5 minutes. Without Windows Hello, they do not open. Set up a PIN in Settings > Accounts > Sign-in options.")));
    }

    // Closes the windows of the features, so that the pointer comes back
    // and the streams stop before Flux quits.
    public static void CloseWindows()
    {
        foreach (var w in TouchpadWindows.All)
        {
            w.Close();
        }
        DesktopWindows.Current?.Close();
        foreach (var w in BrowseWindows.All)
        {
            w.Quitting = true;
            w.Close();
        }
    }
}
