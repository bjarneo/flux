using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The Omarchy panel: the workspaces as pills, the windows of the active
// workspace, and the pinned shortcuts, with the keys of the focused window
// in the dock at the bottom. The computer runs each action in Hyprland, so
// the Omarchy key bindings work also where keys from this computer do not.
// A click on a window focuses it. An Alt-click on a workspace or an arrow
// moves the focused window. The controller reads the list when the panel
// shows, and the workspaces every 3 seconds. OmarchyPanel.swift of the Mac
// app has the same parts.
public sealed class OmarchyPanel : View
{
    readonly AppModel model;
    readonly DesktopController controller;
    readonly ScrollViewer scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    readonly ScrollViewer strip = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        Focusable = false,
    };

    public OmarchyPanel(AppModel model, DesktopController controller)
    {
        this.model = model;
        this.controller = controller;
        Watch(controller);
        Watch(controller.Plugin.Model);
    }

    DesktopModel Shortcuts => controller.Plugin.Model;

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var state = controller.Shortcuts;
        var loaded = state?.Loaded == true;
        var windows = state?.ActiveWindows ?? [];
        var count = state?.ActiveWindowCount ?? 0;
        strip.Content = Workspaces(state);
        var items = new List<UIElement?>();
        if (state?.Error is { } error)
        {
            items.Add(Ui.Text(error, 12, color: tn.Red, wrap: true).Margin(4, 8, 4, 0));
        }
        else if (!loaded)
        {
            items.Add(Ui.H(8, Parts.Spinner(12), Ui.Text($"Reading the shortcuts of {controller.Name}", 12, color: tn.Sub)).Margin(4, 8, 4, 0));
        }
        items.Add(Parts.ListHeading("Windows", loaded ? $"{count} {(count == 1 ? "window" : "windows")}" : ""));
        if (loaded && state!.Windows is null)
        {
            items.Add(Note($"Update Flux on {controller.Name} to see its windows here."));
        }
        else if (loaded && windows.Count == 0)
        {
            items.Add(Note("No windows on this workspace."));
        }
        foreach (var w in windows)
        {
            items.Add(WindowCard(w));
        }
        items.Add(Parts.ListHeading("Launch", action: new FluxButton("All shortcuts…", ButtonKind.Text, ShowAll)
            .Help($"Show and search all key bindings of {controller.Name}")));
        var pinned = DesktopShortcuts.Pinned(state?.Shortcuts ?? ValueList<DesktopShortcut>.Empty, Shortcuts.Pins);
        if (loaded && pinned.Count == 0)
        {
            items.Add(Note("Pin shortcuts with the star in All shortcuts."));
        }
        if (pinned.Count > 0)
        {
            items.Add(Parts.GridRows(pinned.Select(LaunchKey).ToArray(), 2));
        }
        scroll.Content = Ui.V(Metrics.Gap, items).Margin(10, 2, 10, 16);
        var top = Ui.V(0, strip, Parts.ProgressLine());
        var dock = WindowKeys(windows.FirstOrDefault(w => w.Focused));
        var layout = new DockPanel { Background = tn.Bg };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(dock, Dock.Bottom);
        Ui.Detach(scroll);
        layout.Children.Add(top);
        layout.Children.Add(dock);
        layout.Children.Add(scroll);
        return layout;
    }

    static TextBlock Note(string text) => Ui.Text(text, 12, color: Tn.Current.Sub, wrap: true).Margin(4, 8, 4, 8);

    // True while Alt is down: a click then moves the focused window.
    static bool Moving => Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);

    // Workspaces 1 to 10 as pills. The active one has the accent, and a
    // workspace with windows has a dot. A click switches to the workspace,
    // and an Alt-click moves the focused window there.
    UIElement Workspaces(DesktopShortcutsState? state)
    {
        var tn = Tn.Current;
        var used = (state?.Workspaces ?? ValueList<DesktopWorkspace>.Empty).Where(w => w.Windows > 0).Select(w => w.Id).ToHashSet();
        var pills = new List<UIElement>();
        for (var id = 1; id <= DesktopShortcuts.MaxWorkspace; id++)
        {
            var n = id;
            var active = state?.Active == n;
            var pill = new Border
            {
                Child = Ui.H(5,
                    Ui.Text(n.ToString(System.Globalization.CultureInfo.InvariantCulture), 12, FontWeights.SemiBold, active ? tn.Text : tn.Sub, mono: true),
                    used.Contains(n) ? Ui.Dot(active ? tn.Accent : tn.Sub, 4) : null).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                MinWidth = 34,
                MinHeight = 28,
                Padding = new Thickness(9, 0, 9, 0),
                CornerRadius = new CornerRadius(14),
                Background = active ? tn.AccentTile : tn.Tile,
                BorderBrush = active ? tn.Accent : tn.Line,
                BorderThickness = new Thickness(1),
            };
            var b = new PlainButton(pill, () => SelectWorkspace(n, Moving))
                .Named($"Workspace {n}")
                .Help($"Switch to workspace {n}. Alt-click moves the window there.");
            AutomationProperties.SetItemStatus(b, active ? "Selected" : "");
            b.ContextMenu = Menu(($"Switch to workspace {n}", () => SelectWorkspace(n, false)),
                ($"Move the window to workspace {n}", () => SelectWorkspace(n, true)));
            pills.Add(b);
        }
        return Ui.H(6, pills).Margin(10, 10, 10, 10);
    }

    void SelectWorkspace(int id, bool moveWindow)
    {
        controller.Shortcut(moveWindow ? DesktopShortcuts.MoveToWorkspace(id) : DesktopShortcuts.Workspace(id));
        if (moveWindow)
        {
            model.Show($"Moved the window to workspace {id}");
        }
    }

    // A window of the active workspace: the icon of its app, the app, and
    // the title in mono. The focused window has the accent.
    UIElement WindowCard(DesktopWindow w)
    {
        var tn = Tn.Current;
        var f = w.Focused;
        var app = w.App.Length == 0 ? "Window" : w.App;
        var row = Ui.H(10,
            Ui.Icon(WindowGlyph(w.WindowClass), 15, f ? tn.Accent : tn.Sub, 20),
            Ui.V(2, Ui.Text(app, 13, FontWeights.SemiBold), w.Title.Length > 0 ? Ui.Text(w.Title, 10.5, color: tn.Sub, mono: true) : null).Fill(),
            f ? Ui.Text("Focused", 11, FontWeights.Medium, tn.Accent) : null);
        var tile = Ui.Tile(row, f ? tn.AccentTile : tn.Tile, f ? tn.Accent : tn.Line, 0, borderWidth: f ? 2 : 1);
        tile.Padding = new Thickness(10, 8, 10, 8);
        tile.MinHeight = 46;
        var b = new PlainButton(tile, () =>
        {
            if (!f)
            {
                controller.Shortcut(DesktopShortcuts.FocusWindow(w.Address));
            }
        }).Named(app).Help(f ? w.Title : $"Focus {app}");
        AutomationProperties.SetItemStatus(b, f ? "Focused" : "");
        return b;
    }

    // The icon of the app of a window, from its class.
    public static string WindowGlyph(string windowClass)
    {
        var c = windowClass.ToLowerInvariant();
        bool Has(params string[] names) => names.Any(c.Contains);
        if (Has("alacritty", "kitty", "ghostty", "foot", "wezterm", "konsole", "terminal"))
        {
            return Icons.Commands;
        }
        if (Has("chrom", "firefox", "brave", "zen", "vivaldi", "librewolf", "edge", "qutebrowser", "browser"))
        {
            return ControlGlyphs.Globe;
        }
        if (Has("spotify", "music", "rhythmbox", "amberol"))
        {
            return Icons.Audio;
        }
        if (Has("obsidian", "typora", "notes", "logseq", "xournal"))
        {
            return Icons.Edit;
        }
        if (Has("signal", "telegram", "discord", "slack", "whatsapp", "element", "chat"))
        {
            return Icons.Chat;
        }
        if (Has("nautilus", "thunar", "dolphin", "files", "nemo"))
        {
            return Icons.Folder;
        }
        if (Has("code", "zed", "cursor", "neovide", "jetbrains", "studio"))
        {
            return Icons.Code;
        }
        if (Has("mpv", "vlc", "obs", "celluloid"))
        {
            return ControlGlyphs.Video;
        }
        if (Has("imv", "gimp", "krita", "pinta", "inkscape"))
        {
            return Icons.Photo;
        }
        return ControlGlyphs.Window;
    }

    // A pinned shortcut: its description and its keys in mono.
    UIElement LaunchKey(DesktopShortcut s)
    {
        var tn = Tn.Current;
        var tile = Ui.Tile(Ui.V(2,
            Ui.Text(s.Description, 12.5, FontWeights.SemiBold),
            Ui.Text(DesktopShortcuts.KeysLabel(s.Keys), 10.5, color: tn.Sub, mono: true)), tn.Tile, tn.Line, 0);
        tile.Padding = new Thickness(10, 7, 10, 7);
        tile.MinHeight = 36;
        return new PlainButton(tile, () => controller.Shortcut(DesktopShortcuts.Run(s)))
            .Named(s.Description)
            .Help($"Run {s.Description} on the computer");
    }

    static readonly (DesktopDirection Direction, string Glyph, string Name)[] Arrows =
    [
        (DesktopDirection.Left, ControlGlyphs.Left, "left"),
        (DesktopDirection.Up, ControlGlyphs.Up, "up"),
        (DesktopDirection.Down, ControlGlyphs.Down, "down"),
        (DesktopDirection.Right, ControlGlyphs.Right, "right"),
    ];

    static readonly (string Label, string Help, DesktopAction Action)[] Actions =
    [
        ("close", "Close the window", DesktopAction.Close),
        ("full", "Full screen", DesktopAction.Fullscreen),
        ("float", "Float or tile the window", DesktopAction.Float),
        ("split", "Toggle the split", DesktopAction.Split),
    ];

    // The keys of the focused window in the dock: the arrows focus the
    // window in that direction, and an Alt-click swaps the window there.
    // Under them, close, full screen, float, and split. The menu of the
    // action keys holds Focus the next window and Toggle the scratchpad.
    UIElement WindowKeys(DesktopWindow? focused)
    {
        var tn = Tn.Current;
        var arrows = Arrows.Select(a =>
        {
            var key = DockKey(Ui.Icon(a.Glyph, 13, tn.Text), tn.Line, $"Focus the window {a.Name}. Alt-click moves it.",
                () => controller.Shortcut(Moving ? DesktopShortcuts.Swap(a.Direction) : DesktopShortcuts.Focus(a.Direction)));
            key.Named($"Focus the window {a.Name}");
            key.ContextMenu = Menu(($"Focus the window {a.Name}", () => controller.Shortcut(DesktopShortcuts.Focus(a.Direction))),
                ($"Move the window {a.Name}", () => controller.Shortcut(DesktopShortcuts.Swap(a.Direction))));
            return (UIElement)key;
        }).ToArray();
        var actions = Actions.Select(a =>
        {
            var red = a.Action == DesktopAction.Close;
            var key = DockKey(Ui.Text(a.Label, 12, FontWeights.Medium, red ? tn.Red : tn.Text, mono: true), red ? tn.Red : tn.Line, a.Help,
                () => controller.Shortcut(DesktopShortcuts.Action(a.Action)));
            key.Named(a.Help);
            key.ContextMenu = Menu(("Focus the next window", () => controller.Shortcut(DesktopShortcuts.Action(DesktopAction.NextWindow))),
                ("Toggle the scratchpad", () => controller.Shortcut(DesktopShortcuts.Action(DesktopAction.Scratchpad))));
            return (UIElement)key;
        }).ToArray();
        var line = focused is { } f ? Texts.ContextLine(f.App, f.Title) : "an arrow focuses a window";
        var body = Ui.V(8,
            Ui.H(6, Ui.Text("Window", 11.5, FontWeights.Medium, tn.Sub), Ui.Text("· " + line, 10.5, color: tn.Sub, mono: true).Fill()).Margin(4, 0, 4, 0),
            Parts.GridRows(arrows, 4),
            Parts.GridRows(actions, 4));
        return Parts.PageDock(body, 12);
    }

    static PlainButton DockKey(UIElement label, System.Windows.Media.Brush border, string help, Action run)
    {
        var tn = Tn.Current;
        var tile = new Border
        {
            Child = new Border { Child = label, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            Height = 36,
            CornerRadius = new CornerRadius(10),
            Background = tn.Tile,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
        };
        return new PlainButton(tile, run).Help(help);
    }

    static ContextMenu Menu(params (string Title, Action Run)[] items)
    {
        var menu = new ContextMenu();
        foreach (var (title, run) in items)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => run();
            menu.Items.Add(item);
        }
        return menu;
    }

    void ShowAll() => AllShortcuts.Open(Window.GetWindow(this), model.Core, controller);
}

// All shortcuts of the computer, with a search. A click runs a shortcut,
// and the star pins it to the panel. The search has the clear key and the
// mic key, and a dictation replaces the search. AllShortcuts of
// OmarchyPanel.swift has the same parts.
public sealed class AllShortcuts : Window
{
    readonly DesktopController controller;
    readonly ScrollViewer list = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };

    // Shows the shortcuts in a dialog of the owner.
    public static void Open(Window? owner, FluxCore core, DesktopController controller) => new AllShortcuts(owner, core, controller).ShowDialog();

    public AllShortcuts(Window? owner, FluxCore core, DesktopController controller)
    {
        this.controller = controller;
        var tn = Tn.Current;
        var all = controller.Shortcuts?.Shortcuts ?? ValueList<DesktopShortcut>.Empty;
        Search = new TextBox
        {
            FontSize = 13,
            MinHeight = 34,
            VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(2, 0, 2, 0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = tn.Text,
            CaretBrush = tn.Accent,
            FontFamily = Faces.Body,
        };
        AutomationProperties.SetName(Search, "Search the shortcuts");
        var prompt = Ui.Text("Search, for example workspace or browser", 13, color: tn.Dim);
        var field = new Border
        {
            Child = FieldKeys.Row(AgentParts.WithHint(Search, prompt), Search),
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            BorderThickness = new Thickness(1),
            Background = tn.Bg,
            BorderBrush = tn.LineHi,
            Padding = new Thickness(6, 0, 6, 0),
        };
        Voice = VoiceBar.Search(core, Search, field);
        Search.TextChanged += (_, _) => Fill(all);
        Fill(all);
        var done = new FluxButton("Done", ButtonKind.Filled, Close) { IsDefault = true };
        var layout = new DockPanel();
        var head = Ui.V(12, Ui.Text($"All shortcuts · {all.Count}", 15, FontWeights.SemiBold), Voice).Margin(0, 0, 0, 12);
        var foot = Ui.H(8, Ui.Spacer(), done).Margin(0, 12, 0, 0);
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(foot, Dock.Bottom);
        layout.Children.Add(head);
        layout.Children.Add(foot);
        layout.Children.Add(list);
        Title = "All shortcuts";
        Owner = owner;
        Width = 440;
        Height = 520;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Background = tn.TileHi;
        Foreground = tn.Text;
        FontFamily = Faces.Body;
        Content = Ui.Box(layout, 20, 20, 20, 20);
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
        Loaded += (_, _) => Search.Focus();
    }

    // The search field. Tests set it.
    internal TextBox Search { get; }

    // The search with the mic key. Tests read it.
    internal VoiceBar Voice { get; }

    // Lists the shortcuts that match the search.
    void Fill(IReadOnlyList<DesktopShortcut> all)
    {
        var tn = Tn.Current;
        var model = controller.Plugin.Model;
        var rows = DesktopShortcuts.Search(all, Search.Text).Select(s =>
        {
            var pinned = model.Pins.Contains(s.Description);
            var run = new PlainButton(Ui.V(2,
                Ui.Text(s.Description, 13, FontWeights.SemiBold),
                s.Keys.Length > 0 ? Ui.Text(DesktopShortcuts.KeysLabel(s.Keys), 11, color: tn.Sub, mono: true) : null).Margin(4, 4, 4, 4), () =>
            {
                Close();
                controller.Shortcut(DesktopShortcuts.Run(s));
            }).Named(s.Description).Help($"Run {s.Description}");
            var star = new PlainButton(Ui.Icon(pinned ? ControlGlyphs.StarFilled : ControlGlyphs.Star, 14, pinned ? tn.Yellow : tn.Sub).Margin(8), () =>
            {
                model.TogglePin(s);
                Fill(all);
            });
            var help = pinned ? $"Unpin {s.Description}" : $"Pin {s.Description} to Launch";
            star.Named(help).Help(help);
            return (UIElement)Ui.H(8, run.Fill(), star);
        });
        list.Content = Ui.V(2, rows);
    }
}
