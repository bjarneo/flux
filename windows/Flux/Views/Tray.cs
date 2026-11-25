using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FluxKit;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Flux;

// The Flux mark in the tray: dimmed while no paired computer is connected,
// with the count of the items that need the user. A click opens the panel,
// and the right button opens the menu. The menu bar extra of the Mac app has
// the same job.
public sealed class Tray : IDisposable
{
    readonly AppModel model;
    readonly Forms.NotifyIcon icon = new();
    readonly TrayPanel panel;
    Drawing.Icon? drawn;
    string drawnKey = "";

    public Tray(AppModel model, Action showMain, Action showSettings, Action quit)
    {
        this.model = model;
        panel = new TrayPanel(model, showMain, showSettings, quit);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Flux", null, (_, _) => showMain());
        menu.Items.Add("Settings…", null, (_, _) => showSettings());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Flux", null, (_, _) => quit());
        icon.ContextMenuStrip = menu;
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
            {
                panel.Toggle();
            }
        };
        icon.Visible = true;
        model.PropertyChanged += (_, _) => Draw();
        if (model.Core.Plugin<HerdrPlugin>() is { } herdr)
        {
            herdr.Model.PropertyChanged += (_, _) => Draw();
        }
        if (model.Core.Plugin<ApprovePlugin>() is { } approve)
        {
            approve.Model.PropertyChanged += (_, _) => Draw();
        }
        Tn.Changed += Draw;
        Draw();
    }

    // Draws the icon and the tooltip for the state.
    public void Draw()
    {
        var count = Inbox.NeedsYou(model);
        var online = model.ConnectedPaired.Count > 0;
        var light = ThisComputer.TaskbarLight;
        icon.Text = count == 0 ? "Flux" : $"Flux, {Texts.NeedsText(count)}";
        var key = $"{count}|{online}|{light}|{Tn.Current.Palette.Accent}";
        if (key == drawnKey)
        {
            return;
        }
        drawnKey = key;
        var old = drawn;
        drawn = Mark(32, online, light, count);
        icon.Icon = drawn;
        old?.Dispose();
    }

    // The mark on a 16-unit grid: a square ring of 10 units at 3 units with
    // a 2-unit stroke, and a bar of 2 by 14 units at 7 units in the accent.
    static Drawing.Icon Mark(int size, bool online, bool light, int count)
    {
        using var bitmap = new Drawing.Bitmap(size, size);
        using (var g = Drawing.Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var unit = size / 16f;
            var alpha = online ? 255 : 115;
            var ink = light ? Drawing.Color.FromArgb(alpha, 0x34, 0x3B, 0x58) : Drawing.Color.FromArgb(alpha, 0xE6, 0xE9, 0xF5);
            var a = Tn.Current.Palette.Accent;
            var accent = Drawing.Color.FromArgb(alpha, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF);
            using (var pen = new Drawing.Pen(ink, 2 * unit))
            {
                g.DrawRectangle(pen, 3 * unit + unit, 3 * unit + unit, 8 * unit, 8 * unit);
            }
            using (var bar = new Drawing.SolidBrush(accent))
            {
                g.FillRectangle(bar, 7 * unit, 1 * unit, 2 * unit, 14 * unit);
            }
            if (count > 0)
            {
                var r = Tn.Current.Palette.Red;
                using var red = new Drawing.SolidBrush(Drawing.Color.FromArgb(255, (r >> 16) & 0xFF, (r >> 8) & 0xFF, r & 0xFF));
                g.FillEllipse(red, size - 7 * unit, 0, 7 * unit, 7 * unit);
            }
        }
        var handle = bitmap.GetHicon();
        try
        {
            return (Drawing.Icon)Drawing.Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        drawn?.Dispose();
        panel.Close();
    }
}

// The panel of the tray: the count of the items that need the user, the 2
// newest items that need the user as chat cards with their choices or with
// Deny and Approve, the next 3 items as rows, a menu for each online
// computer, and the app actions. It shows near the tray and hides when it
// loses the focus. A card reads a fresh output each time that the panel
// opens. MenuBarView.swift of the Mac app has the same parts. The panel does
// not use the scope.
public sealed class TrayPanel : Window
{
    readonly AppModel model;
    readonly Action showMain;
    readonly Action showSettings;
    readonly Action quit;
    readonly PanelView view;

    public TrayPanel(AppModel model, Action showMain, Action showSettings, Action quit)
    {
        this.model = model;
        this.showMain = showMain;
        this.showSettings = showSettings;
        this.quit = quit;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        FontFamily = Faces.Body;
        view = new PanelView(this);
        Content = view;
        Deactivated += (_, _) => Hide();
        InputBindings.Add(new KeyBinding(new Relay(Hide), Key.Escape, ModifierKeys.None));
        // The panel only hides, until the app quits.
        Closing += (_, e) => e.Cancel = !quitting;
    }

    bool quitting;

    public new void Close()
    {
        quitting = true;
        base.Close();
    }

    public void Toggle()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        view.Redraw();
        Background = Tn.Current.Bg;
        Show();
        UpdateLayout();
        // Near the tray: the bottom right of the work area of the screen
        // with the pointer.
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
        Activate();
    }

    sealed class PanelView : View
    {
        readonly TrayPanel panel;
        readonly EventCards cards;

        public PanelView(TrayPanel panel)
        {
            this.panel = panel;
            cards = new EventCards(panel.model);
            foreach (var m in panel.model.InboxModels())
            {
                Watch(m);
            }
            Watch(ChatAnswers.Shared);
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            var model = panel.model;
            var all = model.InboxItems();
            var seen = model.ChatSeen(all);
            var herdr = model.Core.Plugin<HerdrPlugin>()?.Model;
            // The newest first, by the time that each item got its state.
            var times = all.ToDictionary(i => i.Key, i => i.Content is InboxContent.Agent a && herdr?.AgentSince(a.DeviceId, a.Value.Pane) is { } since
                ? since
                : seen.TryGetValue(i.Key, out var at) ? at : DateTimeOffset.Now);
            var newest = all.OrderByDescending(i => times[i.Key]).ToArray();
            var urgent = newest.Where(i => i.Kind.NeedsYou()).ToArray();
            var rest = urgent.Skip(2).Concat(newest.Where(i => !i.Kind.NeedsYou())).Take(3).ToArray();
            cards.Keep(all.Select(i => i.Key));
            var items = new List<UIElement?>
            {
                Ui.H(8, urgent.Length > 0 ? Ui.Dot(tn.Red) : null, Ui.Text(Texts.NeedsText(urgent.Length), 13, FontWeights.SemiBold)),
            };
            if (model.Paired.Count == 0)
            {
                items.Add(Ui.Text("No computer is paired. Open Flux to pair your Omarchy computer.", 12, color: tn.Sub, wrap: true));
            }
            foreach (var item in urgent.Take(2))
            {
                items.Add(cards.Card(item, times[item.Key]));
            }
            foreach (var item in rest)
            {
                items.Add(Row(item));
            }
            var online = model.ConnectedPaired;
            if (online.Count > 0)
            {
                items.Add(Ui.Divider());
                foreach (var d in online)
                {
                    items.Add(ComputerMenu(d));
                }
            }
            items.Add(Ui.Divider());
            items.Add(Ui.H(4,
                new FluxButton("Open Flux", ButtonKind.Text, () => Run(panel.showMain)),
                new FluxButton("Settings…", ButtonKind.Text, () => Run(panel.showSettings)),
                Ui.Spacer(8),
                new FluxButton("Quit Flux", ButtonKind.Text, () => Run(panel.quit))));
            return new Border
            {
                Child = Ui.V(10, items),
                Background = tn.Bg,
                BorderBrush = tn.LineHi,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12),
            };
        }

        void Run(Action action)
        {
            panel.Hide();
            action();
        }

        // A next item: the state, the source, and the title. A click opens
        // the chat of the item in the main window: the chat of an agent, or
        // the chat of the computer of an approval. A pair request opens its
        // pairing page.
        UIElement Row(InboxItem item)
        {
            var tn = Tn.Current;
            var model = panel.model;
            var source = string.Join(" · ", item.SourceParts);
            UIElement mark = item.Content is InboxContent.Agent a ? AgentParts.StatusMark(a.Value.Status, 7, 10) : Ui.Dot(item.Tone.Brush(), 7);
            var body = Ui.V(2,
                Ui.H(6, mark, Ui.Text(item.StateWord, 11, FontWeights.Medium, item.Tone.Brush()),
                    source.Length > 0 ? Ui.Text("· " + source, 11, color: tn.Sub, mono: true).Fill() : null),
                Ui.Text(item.Title, 13, FontWeights.SemiBold));
            var tile = Ui.Tile(body, tn.Tile, item.Kind.NeedsYou() ? tn.Red : tn.Line, 0, Metrics.SmallCorner);
            tile.Padding = new Thickness(10, 6, 10, 6);
            tile.MinHeight = Metrics.RowHeight;
            var name = string.Join(", ", new[] { item.Title }.Concat(item.SourceParts).Append(item.Computer).Where(p => p.Length > 0));
            var button = new PlainButton(tile, () => Run(() =>
            {
                switch (item.Content)
                {
                    case InboxContent.Agent a:
                        model.OpenChat(new ChatKey.Agent(a.DeviceId, a.Value.Pane));
                        break;
                    case InboxContent.Approval r:
                        model.OpenChat(new ChatKey.Computer(r.Request.ComputerId));
                        break;
                    case InboxContent.Pair p:
                        model.Go(Destination.Computers);
                        model.Push(new Route.Pairing(p.DeviceId));
                        break;
                }
                panel.showMain();
            })).Named(name).Help("Open the chat in Flux");
            System.Windows.Automation.AutomationProperties.SetItemStatus(button, item.StateWord);
            return button;
        }

        // A row for an online computer. Its menu holds the actions of the features.
        UIElement ComputerMenu(DeviceSnapshot d)
        {
            var tn = Tn.Current;
            var row = Ui.H(10, Parts.LinkDot(true), Ui.Text(d.Name, 13, FontWeights.SemiBold).Fill(), Ui.Icon(Icons.ChevronRight, 11, tn.Sub));
            var tile = Ui.Tile(row, tn.Tile, tn.Line, 0, Metrics.SmallCorner);
            tile.Padding = new Thickness(10, 6, 10, 6);
            tile.MinHeight = Metrics.RowHeight;
            var button = new PlainButton(tile, () => { }).Named(d.Name);
            var menu = new ContextMenu();
            foreach (var (title, run) in TrayActions.For(panel.model, d))
            {
                var item = new MenuItem { Header = title };
                item.Click += (_, _) => Run(run);
                menu.Items.Add(item);
            }
            button.Click += (_, _) =>
            {
                menu.PlacementTarget = button;
                menu.IsOpen = true;
            };
            return button;
        }
    }
}

// The actions of the features for 1 computer in the tray panel.
public static class TrayActions
{
    public static List<Func<AppModel, DeviceSnapshot, (string Title, Action Run)?>> Makers { get; } = [];

    public static IEnumerable<(string Title, Action Run)> For(AppModel model, DeviceSnapshot d)
    {
        foreach (var make in Makers)
        {
            if (make(model, d) is { } a)
            {
                yield return a;
            }
        }
        yield return ("Ping", () => model.Core.Plugin<PingPlugin>()?.Ping(d.Id));
    }
}
