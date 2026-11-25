using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The detail column of Chats: the chat of a computer or of an agent, see
// AppModel.ShownChat. Before the first pairing, it shows the pairing guide.
// Each chat draws its own top bar, so the window shows no header over it.
// The chat of each computer stays, so that it keeps its draft and its place.
// The chat of an agent reads the output while it shows. The design puts the
// chats in the detail column of the Mac app too.
public sealed class ChatsPage : Page
{
    readonly Dictionary<string, ComputerChat> computers = [];
    readonly Dictionary<string, AgentsWindowModel> agentModels = [];
    readonly ScrollViewer guide = Ui.Scroll(new Border());
    AgentDetail? agent;
    string agentDevice = "";

    public ChatsPage(AppModel model) : base(model)
    {
        // The chat of an agent ends its watch when the page leaves the window.
        Unloaded += (_, _) => CloseAgent();
    }

    public override string Title => "Chats";

    public override bool OwnHeader => true;

    // The chat of the agent on screen, or null. The window sends Ctrl+R and Ctrl+D to it.
    internal AgentDetail? Agent => agent;

    // The chat of the computer on screen, or null. Tests read it.
    internal ComputerChat? Computer => Content as ComputerChat;

    protected override UIElement Build()
    {
        // The chats of computers that are no longer paired go.
        foreach (var id in computers.Keys.Where(id => Model.PairedDevice(id) is null).ToArray())
        {
            computers.Remove(id);
            agentModels.Remove(id);
        }
        var shown = Model.ShownChat;
        if (shown is ChatKey.Agent a && Model.Core.Plugin<HerdrPlugin>() is { } plugin)
        {
            if (agent is null || agent.Pane != a.Pane || agentDevice != a.DeviceId)
            {
                CloseAgent();
                if (!agentModels.TryGetValue(a.DeviceId, out var m))
                {
                    agentModels[a.DeviceId] = m = new AgentsWindowModel(Model, a.DeviceId, plugin, a.Pane);
                }
                agent = new AgentDetail(m, a.Pane, chat: true);
                agentDevice = a.DeviceId;
            }
            return agent;
        }
        CloseAgent();
        if (shown is null)
        {
            guide.Content = Ui.Column(PairGuide.Build(Model), 16, 16);
            return guide;
        }
        if (!computers.TryGetValue(shown.DeviceId, out var chat))
        {
            computers[shown.DeviceId] = chat = new ComputerChat(Model, shown.DeviceId);
        }
        return chat;
    }

    void CloseAgent()
    {
        agent?.Close();
        agent = null;
    }
}

// The chat of 1 computer: the top bar, the progress line, the thread of that
// computer with the newest entry at the bottom, and the dock. The thread
// holds the links, texts, clips, and files that this computer sent, the
// files and the last clip of the computer, its open approval, and the
// answers. The computer writes on the left, and what this computer sent
// shows on the right. The agents have chats of their own, so they do not
// show here. Files and text that the user drops on the chat go to the
// computer. ChatScreen.kt of the Android app has the same parts.
public sealed class ComputerChat : View
{
    readonly AppModel model;
    readonly ScrollViewer scroll = Ui.Scroll(new Border());
    readonly ChatDock dock;
    readonly DockPanel layout = new();
    readonly Border barHost = new();
    readonly Border lineHost = new();
    bool atEnd = true;
    int lastCount;

    public ComputerChat(AppModel model, string deviceId)
    {
        this.model = model;
        DeviceId = deviceId;
        dock = new ChatDock(model, deviceId);
        AllowDrop = true;
        Drop += (_, e) => ShareViews.Drop(model, e, deviceId);
        DockPanel.SetDock(barHost, Dock.Top);
        DockPanel.SetDock(lineHost, Dock.Top);
        DockPanel.SetDock(dock.Root, Dock.Bottom);
        layout.Children.Add(barHost);
        layout.Children.Add(lineHost);
        layout.Children.Add(dock.Root);
        Ui.Detach(scroll);
        layout.Children.Add(scroll);
        Watch(model);
        foreach (var m in ChatFeed.Models(model))
        {
            Watch(m);
        }
        Watch(Batteries.Model(model));
        scroll.ScrollChanged += (_, e) =>
        {
            if (e.ExtentHeightChange == 0)
            {
                atEnd = scroll.VerticalOffset >= scroll.ScrollableHeight - 48;
            }
        };
    }

    // The ID of the computer of the chat.
    public string DeviceId { get; }

    // The dock with the field, for the tests.
    internal ChatDock Composer => dock;

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (model.PairedDevice(DeviceId) is not { } d)
        {
            return Parts.Unavailable(Icons.Laptop, "The computer is gone", "It is no longer paired with this computer.");
        }
        var battery = Batteries.Of(model, d.Id);
        var context = ChatParts.Context(d, battery);
        if (!d.Online && model.LastSeen(d.Id) is { } seen)
        {
            context += " · last seen " + ChatParts.ShortTime(seen);
        }
        barHost.Child = ChatParts.Bar(ChatParts.Picture(Texts.Symbol(d), tn.Text, tn.Tile, tn.Line, tn.Bg, d.Online ? tn.Green : null),
            d.Name, context, Menu(d));
        lineHost.Child = Parts.ProgressLine(ShareViews.Progress(model, d.Id));
        dock.Update();
        var entries = ChatFeed.Entries(model, d.Id);
        var items = new List<UIElement?>();
        if (entries.Count == 0)
        {
            items.Add(Ui.Text("Approvals and the files and clips from this computer show here. So do the links, text, and files that you send. To send files, drop them on this chat.",
                12, color: tn.Sub, wrap: true, align: TextAlignment.Center).Margin(24, 0, 24, 0));
        }
        DateTimeOffset? last = null;
        foreach (var e in entries)
        {
            if (last is null || last.Value.ToLocalTime().Date != e.At.ToLocalTime().Date)
            {
                items.Add(Ui.Text(Texts.DayText(e.At), 11, color: tn.Sub, align: TextAlignment.Center).Align(HorizontalAlignment.Center).Margin(0, 2, 0, 2));
            }
            last = e.At;
            items.Add(e.View);
        }
        items.Add(ChatNotices.Build(model, d));
        var thread = new Border
        {
            Child = Ui.V(10, items),
            MaxWidth = Metrics.MaxContentWidth,
            Padding = new Thickness(14, 14, 14, 16),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        scroll.Content = thread;
        // The view follows a new entry while it shows the end. When the user
        // scrolls up, it stays there, unless this computer sent the entry.
        if (entries.Count != lastCount && (atEnd || entries.LastOrDefault()?.Mine == true))
        {
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, scroll.ScrollToEnd);
        }
        lastCount = entries.Count;
        return layout;
    }

    // The menu of the chat: Control with this computer in scope, the agents
    // window, and Start Agent.
    UIElement Menu(DeviceSnapshot d)
    {
        var button = new FluxButton("", ButtonKind.Text, () => { }, Icons.More).Named("More actions").Help("More actions");
        button.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = button, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            menu.Items.Add(Item("Control", () =>
            {
                model.SetScope(d.Id);
                model.Go(Destination.Control);
            }));
            var herdr = model.Core.Plugin<HerdrPlugin>();
            if (herdr is not null && d.Accepts(PacketType.Herdr))
            {
                menu.Items.Add(Item("Agents Window", () => AgentsWindows.Show(model, d.Id)));
                if (d.Online && AgentsFeature.CanStart(model, d))
                {
                    menu.Items.Add(Item("Start Agent…", () => AgentsFeature.Start(model, d.Id)));
                }
            }
            menu.IsOpen = true;
        };
        return button;
    }

    static MenuItem Item(string header, Action run)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => run();
        return item;
    }
}

// 1 entry of the chat: its time, its view, and whether this computer wrote it.
public sealed record ChatEntryView(string Id, DateTimeOffset At, UIElement View, bool Mine = false);

// The entries of the chat of a computer in the order of Chat.Entries of
// FluxKit: the files, the texts, and the clips of the share feature, the
// last clip, the answers to approvals, and the open approval of the
// computer. ChatView.swift of the Mac app has the same order.
public static class ChatFeed
{
    // The models that the chats watch.
    public static IEnumerable<System.ComponentModel.INotifyPropertyChanged> Models(AppModel model) =>
        new System.ComponentModel.INotifyPropertyChanged?[]
        {
            model.Core.Plugin<ClipboardPlugin>()?.Model,
            model.Core.Plugin<SharePlugin>()?.Model,
            model.Core.Plugin<HerdrPlugin>()?.Model,
            model.Core.Plugin<ApprovePlugin>()?.Model,
        }.OfType<System.ComponentModel.INotifyPropertyChanged>();

    // The entries of the chat of the computer, oldest first.
    public static IReadOnlyList<ChatEntryView> Entries(AppModel model, string deviceId)
    {
        var share = model.Core.Plugin<SharePlugin>()?.Model;
        var approve = model.Core.Plugin<ApprovePlugin>()?.Model;
        InboxItem[] items = approve?.Current is { } open && open.ComputerId == deviceId
            ? [new InboxItem(new InboxContent.Approval(open), open.ComputerName)]
            : [];
        var entries = Chat.Entries((IEnumerable<SentItem>?)share?.Sent ?? [], (IEnumerable<FileTransfer>?)share?.Transfers ?? [],
            model.Core.Plugin<ClipboardPlugin>()?.Model.Last, (IEnumerable<ApproveRecord>?)approve?.History ?? [], items, (_, _) => null,
            model.ChatSeen(items), deviceId);
        var shared = ShareViews.Entries(model, deviceId).ToDictionary(e => e.Id);
        var list = new List<ChatEntryView>();
        foreach (var e in entries)
        {
            switch (e)
            {
                case ChatEntry.Event { Item.Content: InboxContent.Approval a } ev:
                    list.Add(new ChatEntryView(e.Id, e.At, ApproveCards.ApprovalCard(model, ev.Item, a.Request, ev.Time)));
                    break;
                case ChatEntry.Clip c:
                    list.Add(new ChatEntryView(e.Id, e.At, Cards.ClipCard(c.Value)));
                    break;
                case ChatEntry.Answer a:
                    // The user just answered, so the thread follows it.
                    list.Add(new ChatEntryView(e.Id, e.At, ApproveCards.AnswerCard(a.Record), Mine: true));
                    break;
                default:
                    if (shared.TryGetValue(e.Id, out var view))
                    {
                        list.Add(view);
                    }
                    break;
            }
        }
        return list;
    }
}

// The notices under the entries of the chat of a computer: that Flux
// connects to it, that it just paired, or that it is not reachable.
public static class ChatNotices
{
    public static UIElement Build(AppModel model, DeviceSnapshot d)
    {
        var tn = Tn.Current;
        var rows = new List<UIElement?>();
        if (!d.Online && model.Connecting)
        {
            rows.Add(Ui.H(10, Parts.Spinner(), Ui.Text($"Connecting to {d.Name}", 12, color: tn.Sub)).Margin(10, 0, 10, 0));
        }
        if (model.NewlyPairedId == d.Id)
        {
            rows.Add(Notice(Ui.Icon(Icons.Check, 15, tn.Green), $"{d.Name} is paired. Its agents show in the list of chats, and its files and clips show here."));
        }
        if (!d.Online && !model.Connecting)
        {
            rows.Add(Notice(Parts.LinkDot(false), $"{d.Name} is not reachable. Its agents do not show in the list of chats.",
                new FluxButton("Retry", ButtonKind.Text, model.Retry)));
        }
        return Ui.V(Metrics.Gap, rows);
    }

    // 1 notice: a mark, the text, and the action at the end of the row.
    public static UIElement Notice(UIElement mark, string text, UIElement? action = null)
    {
        var tn = Tn.Current;
        var row = Ui.H(10, Ui.Box(mark, 0, 0, 0, 0).Width(18), Ui.Text(text, 12, wrap: true).Fill(), action);
        var tile = Ui.Tile(row, tn.OffTile, tn.Line, 0);
        tile.Padding = new Thickness(10, 6, 10, 6);
        tile.MinHeight = 36;
        return tile;
    }
}

// The guide before the first pairing: what Flux is, how to set up Flux on
// the Omarchy computer, and the computers to pair, in a large tile with the
// active border.
public static class PairGuide
{
    const string InstallGuide = "https://github.com/bjarneo/flux/blob/master/docs/install.md";
    const string SetupCommand = "flux-cli setup";

    public static UIElement Build(AppModel model)
    {
        var tn = Tn.Current;
        var available = model.Available.Where(d => d.Online).ToArray();
        var items = new List<UIElement?>
        {
            Ui.Text("Pair your Omarchy computer", 20, FontWeights.SemiBold, wrap: true),
            Paragraph("Flux lets this computer answer agents, approve sudo, and send files to your Omarchy computer."),
        };
        var install = new FluxButton("Read the install guide", ButtonKind.Text, () => App.OpenUrl(InstallGuide), Icons.Open).Margin(-8, 0, 0, 0);
        if (available.Length == 0)
        {
            items.Add(Step("1. Set up Flux on the computer",
                Paragraph("Install the Flux package on the computer. Then start fluxd for your desktop user:"),
                Parts.CommandBlock(SetupCommand),
                install));
            items.Add(Step("2. Pair this computer", PairStep(model, available)));
        }
        else
        {
            items.Add(Step("Pair this computer", PairStep(model, available)));
            items.Add(Step("Another computer", Paragraph($"To add a computer, run {SetupCommand} on it."), install));
        }
        var tile = new Border
        {
            Child = Ui.V(10, items),
            Background = tn.Tile,
            BorderBrush = tn.ActiveBorder(),
            BorderThickness = new Thickness(2),
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            Padding = new Thickness(20),
        };
        return tile;
    }

    static UIElement Paragraph(string text) => Ui.Text(text, 13, color: Tn.Current.Sub, wrap: true);

    static UIElement Step(string title, params UIElement?[] content) =>
        Ui.V(8, new UIElement?[] { Ui.Text(title, 15, FontWeights.SemiBold) }.Concat(content)).Margin(0, 6, 0, 0);

    static UIElement PairStep(AppModel model, IReadOnlyList<DeviceSnapshot> available)
    {
        var items = new List<UIElement?> { Paragraph("Select the computer. Then compare the key on both screens.") };
        foreach (var d in available)
        {
            items.Add(Shared.AvailableRow(d, () => model.Push(new Route.Pairing(d.Id))));
        }
        items.Add(Shared.ScanRow(model, true, available.Count == 0,
            $"Check that you ran {SetupCommand} on the computer, and that both are on the same network."));
        return Ui.V(8, items);
    }
}

// The cards of the chat.
public static class Cards
{
    // The top row of a card: the state in its color, the source in mono, and the time.
    public static UIElement Head(string state, Brush color, string source, string time, UIElement? mark = null)
    {
        var tn = Tn.Current;
        var row = Ui.H(6,
            mark,
            Ui.Text(state, 12, FontWeights.Medium, color),
            source.Length > 0 ? Ui.Text("· " + source, 12, color: tn.Sub, mono: true).Fill() : Ui.Spacer(),
            Ui.Text(time, 11, color: tn.Sub, mono: true));
        return row.Named(Texts.ContextLine(state, source, time).Replace(" · ", ", "));
    }

    // A card from a computer, on the left at 88% of the column. A card that
    // needs the user takes the full column and a red border of 2 px. A card
    // of the list of chats, list, takes the tile corner on all sides.
    public static UIElement InCard(UIElement head, string title, string detail = "", bool mono = false, bool ask = false,
                                   UIElement? extra = null, UIElement? action = null, bool list = false)
    {
        var tn = Tn.Current;
        var titleText = Ui.Text(title, 14, FontWeights.SemiBold, mono: mono, wrap: true);
        var body = Ui.V(5,
            head,
            titleText,
            detail.Length > 0 ? Ui.Text(detail, 12, color: tn.Sub, mono: true, wrap: true) : null,
            extra,
            action);
        var card = new Border
        {
            Child = body,
            Background = tn.Tile,
            BorderBrush = ask ? tn.Red : tn.Line,
            BorderThickness = new Thickness(ask ? 2 : 1),
            CornerRadius = list ? new CornerRadius(Metrics.TileCorner) : new CornerRadius(14, 14, 14, 4),
            Padding = new Thickness(12, 10, 12, 10),
            HorizontalAlignment = ask ? HorizontalAlignment.Stretch : HorizontalAlignment.Left,
        };
        if (!ask)
        {
            return new PartWidth(card, 0.88);
        }
        return card;
    }

    // A bubble of what this computer sent, on the right at 82% of the column.
    public static UIElement OutBubble(UIElement content, string meta)
    {
        var tn = Tn.Current;
        var bubble = new Border
        {
            Child = Ui.V(4, content, Ui.Text(meta, 11, color: tn.Sub, mono: true)),
            Background = tn.AccentTile,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16, 16, 4, 16),
            Padding = new Thickness(12, 9, 12, 9),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        return new PartWidth(bubble, 0.82, right: true);
    }

    // A text action at the bottom of a card, in the accent.
    public static UIElement TextAction(string label, Action run, string help = "")
    {
        var t = Ui.Text(label, 13, FontWeights.SemiBold, Tn.Current.Accent).MinHeight(24);
        return new PlainButton(t, run) { HorizontalAlignment = HorizontalAlignment.Left }.Help(help.Length > 0 ? help : label);
    }

    // The last clip from a computer. A secret shows "Hidden text" in the
    // body face, and no part of the secret.
    public static UIElement ClipCard(ClipEvent clip)
    {
        var tn = Tn.Current;
        var text = clip.Secret ? ClipEvent.HiddenText : clip.Preview;
        return InCard(Head("Clipboard", tn.Cyan, clip.Computer, Texts.ClockTime(clip.At), Ui.Dot(tn.Cyan, 8)), text, mono: !clip.Secret);
    }

    // A computer that asks to pair. A click opens the pairing page. list
    // draws the card for the list of chats.
    public static UIElement PairCard(AppModel model, DeviceSnapshot d, DateTimeOffset at, bool list = false)
    {
        var tn = Tn.Current;
        return InCard(Head("Pair request", tn.Red, "", Texts.ClockTime(at), Ui.Dot(tn.Red, 8)),
            $"{d.Name} asks to pair", $"Key {Certificates.FormatKey(d.PairKey)}", ask: true, list: list,
            action: TextAction("Compare the key", () =>
            {
                model.Go(Destination.Computers);
                model.Push(new Route.Pairing(d.Id));
            }));
    }
}

// A frame that gives its child a part of the width that it gets, at most,
// on the left or on the right.
public sealed class PartWidth : Decorator
{
    readonly double part;

    public PartWidth(UIElement child, double part, bool right = false)
    {
        this.part = part;
        Child = child;
        if (child is FrameworkElement fe)
        {
            fe.HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        }
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? available.Width : available.Width * part;
        Child?.Measure(new Size(width, available.Height));
        return new Size(available.Width is var w && double.IsInfinity(w) ? Child?.DesiredSize.Width ?? 0 : w, Child?.DesiredSize.Height ?? 0);
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (Child is null)
        {
            return final;
        }
        var width = Math.Min(Child.DesiredSize.Width, final.Width * part);
        var left = Child is FrameworkElement { HorizontalAlignment: HorizontalAlignment.Right } ? final.Width - width : 0;
        Child.Arrange(new Rect(left, 0, width, final.Height));
        return final;
    }
}
