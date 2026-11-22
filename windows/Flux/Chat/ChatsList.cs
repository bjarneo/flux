using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The list of chats in the sidebar: Chats with the count of what needs the
// user and the computers online, the search, and the groups Needs you,
// Agents, and Computers. An approval is a card with Deny and Approve, and a
// pair request is a card with Compare the key. A click on an agent or a
// computer opens its chat in the detail column. The search keeps only the
// chats that hold its text, see Chats.List. The list asks each computer
// that comes online for its agents. ChatsScreen.kt of the Android app has
// the same parts. The design puts the list in the sidebar of the Mac app too.
public sealed class ChatsList : View
{
    readonly AppModel model;
    readonly TextBox search;
    readonly TextBlock searchHint = Ui.Text(SearchHint, 13);
    readonly TextBlock searchIcon = Ui.Icon(Icons.Search, 13);
    readonly Border searchFrame;
    readonly VoiceBar searchBar;
    readonly ScrollViewer scroll = Ui.Scroll(new Border());
    readonly Border headHost = new();
    readonly DockPanel layout = new();
    // The times of the rows that move: the agents that wait and the agents that work.
    readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly List<(TextBlock Text, Func<DateTimeOffset, string> Make)> ticking = [];
    // The first time that the list saw each row with no time of its own.
    readonly SeenClock clock = new();
    string online = "";

    public ChatsList(AppModel model)
    {
        this.model = model;
        Watch(model);
        foreach (var m in ChatFeed.Models(model))
        {
            Watch(m);
        }
        Watch(Batteries.Model(model));
        search = new TextBox
        {
            FontSize = 13,
            MinHeight = 30,
            VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(2, 0, 2, 0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            FontFamily = Faces.Body,
        };
        AutomationProperties.SetName(search, SearchHint);
        searchFrame = new Border
        {
            Child = Ui.H(8, searchIcon, FieldKeys.Row(AgentParts.WithHint(search, searchHint), search).Fill()),
            CornerRadius = new CornerRadius(16),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 0, 8, 0),
        };
        // A dictation replaces the search.
        searchBar = VoiceBar.Search(model.Core, search, searchFrame);
        search.TextChanged += (_, _) => Invalidate();
        search.GotKeyboardFocus += (_, _) => Invalidate();
        search.LostKeyboardFocus += (_, _) => Invalidate();
        search.PreviewKeyDown += (_, e) =>
        {
            // Escape empties the search before it goes back.
            if (e.Key == Key.Escape && search.Text.Length > 0)
            {
                e.Handled = true;
                search.Clear();
            }
        };
        var top = Ui.V(6, headHost, searchBar).Margin(8, 0, 8, 6);
        DockPanel.SetDock(top, Dock.Top);
        layout.Children.Add(top);
        Ui.Detach(scroll);
        layout.Children.Add(scroll);
        ticker.Tick += (_, _) => Tick();
        Loaded += (_, _) => ticker.Start();
        Unloaded += (_, _) => ticker.Stop();
    }

    const string SearchHint = "Search agents, computers, files";

    // The search field. Tests set it.
    internal TextBox Search => search;

    // Gives the focus to the search.
    public void FocusSearch()
    {
        search.Focus();
        search.SelectAll();
    }

    void Tick()
    {
        var now = DateTimeOffset.Now;
        foreach (var (text, make) in ticking)
        {
            text.Text = make(now);
        }
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var paired = model.Paired;
        RequestAgents();
        var needs = Inbox.NeedsYou(model);
        var context = paired.Count == 0 ? "" : Texts.ContextLine(needs > 0 ? $"{needs} need you" : "nothing needs you", Shared.OnlineText(model));
        var head = new PlainButton(Ui.V(1,
                Ui.Text("Chats", 15, FontWeights.SemiBold),
                context.Length > 0 ? Ui.Text(context, 11, color: tn.Sub, mono: true) : null).Margin(6, 2, 6, 2),
            () => model.Go(Destination.Chat)).Named("Chats").Help("Chats (Ctrl+1)");
        AutomationProperties.SetItemStatus(head, Texts.NeedsText(needs));
        AutomationProperties.SetHeadingLevel(head, AutomationHeadingLevel.Level1);
        headHost.Child = head;
        searchBar.Shown(paired.Count > 0);
        searchBar.Enabled = paired.Count > 0;
        searchFrame.Background = tn.Tile;
        searchHint.Foreground = tn.Sub;
        searchIcon.Foreground = tn.Sub;
        searchFrame.BorderBrush = search.IsKeyboardFocused ? tn.Accent : tn.Line;
        search.Foreground = tn.Text;
        search.CaretBrush = tn.Accent;
        ticking.Clear();
        var items = new List<UIElement?>();
        if (paired.Count == 0)
        {
            items.Add(Ui.Text("Your chats show here after the first pairing.", 12, color: tn.Sub, wrap: true).Margin(6, 4, 6, 0));
            scroll.Content = Ui.V(4, items).Margin(8, 0, 8, 12);
            return layout;
        }
        var list = List();
        var shown = model.Destination == Destination.Chat ? model.ShownChat : null;
        var many = model.ConnectedPaired.Count(d => model.Core.Plugin<HerdrPlugin>()?.Model.States.GetValueOrDefault(d.Id)?.Running == true) > 1;
        items.Add(Notice());
        if (list.Needs.Count > 0)
        {
            items.Add(Heading("Needs you", list.Needs.Count.ToString(CultureInfo.InvariantCulture), tn.Red, true));
            foreach (var r in list.Needs)
            {
                items.Add(NeedsRow(r, shown, many));
            }
        }
        if (list.Agents.Count > 0)
        {
            // With 1 computer, the heading names it. With more, each row names its computer.
            var on = list.Agents.OfType<ChatRow.Agent>().Select(a => a.ComputerName).Distinct().ToArray();
            items.Add(Heading("Agents", on.Length == 1 ? "on " + on[0] : "", tn.Sub, list.Needs.Count == 0));
            foreach (var r in list.Agents.OfType<ChatRow.Agent>())
            {
                items.Add(AgentRow(r, shown, many));
            }
        }
        if (list.Computers.Count > 0)
        {
            items.Add(Heading("Computers", "", tn.Sub, list.Needs.Count == 0 && list.Agents.Count == 0));
            foreach (var r in list.Computers.OfType<ChatRow.Computer>())
            {
                items.Add(ComputerRow(r, shown));
            }
        }
        if (list.IsEmpty && search.Text.Trim().Length > 0)
        {
            items.Add(Ui.Text($"No chat holds \"{search.Text.Trim()}\".", 12, color: tn.Sub, wrap: true, align: TextAlignment.Center).Margin(6, 16, 6, 0));
        }
        scroll.Content = Ui.V(4, items).Margin(8, 0, 8, 12);
        return layout;
    }

    // The list for the search, with the chat entries of all computers.
    ChatList List()
    {
        var share = model.Core.Plugin<SharePlugin>()?.Model;
        var herdr = model.Core.Plugin<HerdrPlugin>()?.Model;
        var approve = model.Core.Plugin<ApprovePlugin>()?.Model;
        var log = Chat.Entries((IEnumerable<SentItem>?)share?.Sent ?? [], (IEnumerable<FileTransfer>?)share?.Transfers ?? [],
            model.Core.Plugin<ClipboardPlugin>()?.Model.Last, (IEnumerable<ApproveRecord>?)approve?.History ?? [], [], (_, _) => null,
            new Dictionary<string, DateTimeOffset>());
        return Chats.List(model.State.Devices, (IReadOnlyDictionary<string, HerdrState>?)herdr?.States ?? new Dictionary<string, HerdrState>(),
            approve?.Current, log, (id, pane) => herdr?.AgentSince(id, pane), clock, DateTimeOffset.Now, search.Text);
    }

    // Asks each computer that comes online for its agents.
    void RequestAgents()
    {
        var ids = string.Join(",", model.ConnectedPaired.Select(d => d.Id));
        if (ids == online)
        {
            return;
        }
        online = ids;
        foreach (var d in model.ConnectedPaired.Where(d => d.Accepts(PacketType.Herdr)))
        {
            model.Core.Plugin<HerdrPlugin>()?.Request(d.Id);
        }
    }

    // The state of the links while no paired computer is online: that Flux
    // connects, or that no computer is reachable, with Retry.
    UIElement? Notice()
    {
        var tn = Tn.Current;
        if (model.ConnectedPaired.Count > 0)
        {
            return null;
        }
        if (model.Connecting)
        {
            return Ui.H(10, Parts.Spinner(), Ui.Text("Connecting to your computers", 12, color: tn.Sub)).Margin(6, 4, 6, 4);
        }
        return ChatNotices.Notice(Parts.LinkDot(false), "No computer is reachable.", new FluxButton("Retry", ButtonKind.Text, model.Retry));
    }

    // The heading of a group: the title, and the trailing text in mono and the color at the end.
    static UIElement Heading(string title, string trailing, Brush color, bool first)
    {
        var t = Ui.Text(title, 13, FontWeights.Medium);
        AutomationProperties.SetHeadingLevel(t, AutomationHeadingLevel.Level2);
        return Ui.H(8, t, Ui.Spacer(8), trailing.Length > 0 ? Ui.Text(trailing, 11, color: color, mono: true) : null)
            .Margin(6, first ? 6 : 12, 6, 2).Named(trailing.Length > 0 ? $"{title}, {trailing}" : title);
    }

    // A row of the group Needs you: an approval or a pair request as a card, or an agent that waits.
    UIElement? NeedsRow(ChatRow r, ChatKey? shown, bool many)
    {
        switch (r)
        {
            case ChatRow.Approval a:
                return ApproveCards.ApprovalCard(model, new InboxItem(new InboxContent.Approval(a.Request), a.Request.ComputerName), a.Request, a.At, list: true);
            case ChatRow.Pair p when model.DeviceOf(p.DeviceId) is { } d:
                return Cards.PairCard(model, d, p.At, list: true);
            case ChatRow.Agent a:
                return AgentRow(a, shown, many);
            default:
                return null;
        }
    }

    // An agent: its task, its state word in its color with the agent and the
    // project in mono, and the time at the end. An agent that waits shows
    // how long it waits, an agent that works shows how long it works, and
    // another agent shows the time of its status.
    UIElement AgentRow(ChatRow.Agent r, ChatKey? shown, bool many)
    {
        var tn = Tn.Current;
        var a = r.Value;
        var blocked = a.Status == AgentStatus.Blocked;
        var title = a.Title.Length > 0 ? a.Title : a.Pane;
        var source = Texts.ContextLine(a.Agent, a.Project.Length > 0 ? a.Project : a.Workspace, many ? r.ComputerName : "");
        var key = new ChatKey.Agent(r.DeviceId, a.Pane);
        var selected = key == shown;
        var ground = selected ? tn.Line : blocked ? tn.Tile : tn.Bg;
        var picture = ChatParts.Picture(AgentGlyphs.Agent, a.Status is AgentStatus.Idle or AgentStatus.Unknown ? tn.Sub : tn.Accent,
            blocked ? tn.AccentTile : tn.Tile, blocked ? null : tn.Line, ground, AgentDot(a.Status), a.Status == AgentStatus.Working);
        var line = Ui.H(0,
            Ui.Text(a.Status.Label(), 12, FontWeights.Medium, a.Status.Ink()),
            source.Length > 0 ? Ui.Text(" · " + source, 12, color: tn.Sub, mono: true).Fill() : null);
        var time = Ui.Text("", 11, color: tn.Sub, mono: true);
        Func<DateTimeOffset, string> when = a.Status is AgentStatus.Blocked or AgentStatus.Working
            ? now => AgentTime.When(a.Status, r.At, now)
            : _ => ChatParts.ShortTime(r.At);
        time.Text = when(DateTimeOffset.Now);
        if (a.Status is AgentStatus.Blocked or AgentStatus.Working)
        {
            ticking.Add((time, when));
        }
        return ChatParts.Row(picture, title, line, time, Texts.ContextLine(title, a.Status.Label(), source).Replace(" · ", ", "),
            () => model.OpenChat(key), selected, ask: blocked);
    }

    // The color of the dot of an agent, or null for the turning ring of an agent that works.
    static Brush? AgentDot(AgentStatus s) => s switch
    {
        AgentStatus.Blocked => Tn.Current.Red,
        AgentStatus.Done => Tn.Current.Green,
        AgentStatus.Working => null,
        _ => Tn.Current.Dim,
    };

    // A computer: its name, the newest entry of its chat, and the time of
    // that entry. A computer that is not reachable shows at 55% with the
    // time that it went offline. Without entries, the line shows the link
    // and the battery.
    UIElement ComputerRow(ChatRow.Computer r, ChatKey? shown)
    {
        var tn = Tn.Current;
        var d = r.Device;
        var key = new ChatKey.Computer(d.Id);
        var selected = key == shown;
        var lastSeen = model.LastSeen(d.Id);
        var battery = Batteries.Of(model, d.Id);
        var text = !d.Online
            ? LinkNote.RowLine(false, lastSeen, Texts.ClockTime)!
            : r.Last is { } last ? last.Preview()
            : ChatParts.Capital(ChatParts.Context(d, battery));
        var at = r.Last?.At ?? (d.Online ? null : lastSeen);
        var picture = ChatParts.Picture(Texts.Symbol(d), tn.Text, tn.Tile, tn.Line, selected ? tn.Line : tn.Bg, d.Online ? tn.Green : null);
        var time = at is { } t ? Ui.Text(ChatParts.ShortTime(t), 11, color: tn.Sub, mono: true) : null;
        var name = string.Join(", ", new[] { d.Name, Texts.LinkText(d, battery?.Charge, battery?.Charging == true), text }.Distinct());
        return ChatParts.Row(picture, d.Name, Ui.Text(text, 12, color: tn.Sub), time, name, () => model.OpenChat(key), selected, dim: !d.Online);
    }
}

// The parts of the chats: the picture of a chat with its state dot, a row
// of the list, and the top bar of a chat. The list, the chat of a computer,
// and the chat of an agent use them.
public static class ChatParts
{
    // The size of the picture of a chat in the list and in the top bar.
    public const double PictureSize = 36;

    // The picture of a chat: a glyph on a tile with the chat corner, and the
    // state dot at the bottom right with a ring of the ground. spinner draws
    // the turning ring of an agent that works in the place of the dot.
    public static FrameworkElement Picture(string glyph, Brush tint, Brush fill, Brush? edge, Brush ground, Brush? dot, bool spinner = false)
    {
        var grid = new Grid { Width = PictureSize, Height = PictureSize, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(new Border
        {
            Child = Ui.Icon(glyph, 18, tint),
            Background = fill,
            BorderBrush = edge ?? Brushes.Transparent,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
        });
        FrameworkElement? mark = null;
        if (spinner)
        {
            var host = new Grid { Width = 13, Height = 13 };
            host.Children.Add(Ui.Dot(ground, 13));
            host.Children.Add(Parts.Spinner(9, Tn.Current.Accent).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            mark = host;
        }
        else if (dot is not null)
        {
            mark = new System.Windows.Shapes.Ellipse { Width = 12, Height = 12, Fill = dot, Stroke = ground, StrokeThickness = 2 };
        }
        if (mark is not null)
        {
            mark.HorizontalAlignment = HorizontalAlignment.Right;
            mark.VerticalAlignment = VerticalAlignment.Bottom;
            mark.Margin = new Thickness(0, 0, -3, -3);
            grid.Children.Add(mark);
        }
        return grid;
    }

    // A row of the list: the picture, the title on 1 line, the line under it,
    // and the time at the end. The open chat takes line. A row that needs the
    // user takes tile and a red border. dim shows a computer that is not
    // reachable at 55%. A screen reader reads the row as 1 button with name.
    public static UIElement Row(UIElement picture, string title, UIElement line, UIElement? time, string name, Action open, bool selected,
                                bool ask = false, bool dim = false)
    {
        var tn = Tn.Current;
        var body = Ui.H(10, picture, Ui.V(2, Ui.Text(title, 13, FontWeights.SemiBold), line).Fill(), time);
        var tile = new Border
        {
            Child = body,
            Background = selected ? tn.Line : ask ? tn.Tile : Brushes.Transparent,
            BorderBrush = ask ? tn.Red : Brushes.Transparent,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            Padding = new Thickness(8, 6, 8, 6),
            Opacity = dim ? Metrics.DisabledAlpha : 1,
        };
        var button = new PlainButton(tile, open).Named(name).Help("Open the chat");
        AutomationProperties.SetItemStatus(button, selected ? "Selected" : "");
        return button;
    }

    // The top bar of a chat: the picture, the title, the context line in
    // mono, and the actions at the end.
    public static UIElement Bar(UIElement picture, string title, string context, params UIElement?[] actions)
    {
        var tn = Tn.Current;
        var titles = Ui.V(1,
            Ui.Text(title, 15, FontWeights.SemiBold),
            context.Length > 0 ? Ui.Text(context, 11, color: tn.Sub, mono: true) : null).Fill();
        AutomationProperties.SetHeadingLevel(titles, AutomationHeadingLevel.Level1);
        var row = Ui.H(10, new UIElement?[] { picture, titles }.Concat(actions));
        return new Border { Child = row, Padding = new Thickness(Metrics.Gutter, 8, Metrics.Gutter, 8), Background = tn.Bg };
    }

    // The link and the battery of a computer for a chat: "connected · 82%,
    // charging", "connected", or "not reachable".
    public static string Context(DeviceSnapshot d, BatteryLevel? battery)
    {
        if (!d.Online)
        {
            return "not reachable";
        }
        return battery is { } b ? $"connected · {b.Charge}%" + (b.Charging ? ", charging" : "") : "connected";
    }

    // The text with a capital first letter.
    public static string Capital(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    // The time of a row: the time of day today, else the short date.
    public static string ShortTime(DateTimeOffset at)
    {
        var local = at.ToLocalTime();
        return local.Date == DateTime.Today ? Texts.ClockTime(at) : local.ToString("d", CultureInfo.CurrentCulture);
    }
}
