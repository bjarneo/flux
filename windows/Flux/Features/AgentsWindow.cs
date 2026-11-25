using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The state of 1 agents window: the selected agent and the reply drafts of
// each agent. The reply field of an agent holds its own dictation, see
// VoiceBar. AgentsWindows.swift of the Mac app has the same state.
public sealed class AgentsWindowModel(AppModel app, string deviceId, HerdrPlugin plugin, string? selection) : Model
{
    string? selected = selection;

    public AppModel App { get; } = app;
    public string DeviceId { get; } = deviceId;
    public HerdrPlugin Plugin { get; } = plugin;

    // The pane of the selected agent.
    public string? Selection
    {
        get => selected;
        set => Set(ref selected, value);
    }

    // The reply text of each pane. A draft stays when the user selects another agent.
    public Dictionary<string, string> Drafts { get; } = [];

    public DeviceSnapshot? Device => App.DeviceOf(DeviceId);

    // The name of the computer for the texts.
    public string Name => Device?.Name ?? "the computer";

    // The agents of all herdr sessions of the computer.
    public HerdrState? Herdr => Plugin.Model.States.GetValueOrDefault(DeviceId);

    // The agents of the herdr session that the list shows.
    public HerdrState? Shown => Plugin.Model.Scoped(DeviceId);
}

// The agents windows, 1 for each computer. AgentsWindows.swift of the Mac app
// has the same rules.
public static class AgentsWindows
{
    static readonly Dictionary<string, AgentsWindow> Windows = [];

    // The open windows by device ID. Tests read it.
    internal static IReadOnlyDictionary<string, AgentsWindow> Open => Windows;

    // True while the agents window of the computer deviceId is open.
    public static bool IsOpen(string deviceId) => Windows.ContainsKey(deviceId);

    // Shows the agents window of a computer, and opens it when it is not
    // open. pane selects that agent. startAgent opens the dialog that starts
    // an agent. herdr keeps 1 output of each computer, so an agent chat of
    // the same computer in the main window gives its place to the chat of
    // the computer.
    public static void Show(AppModel app, string deviceId, string? pane = null, bool startAgent = false)
    {
        if (app.Core.Plugin<HerdrPlugin>() is not { } plugin)
        {
            return;
        }
        app.YieldAgentChat(deviceId);
        // The list shows the session of the agent.
        if (pane is not null)
        {
            plugin.Model.Reveal(deviceId, pane);
        }
        if (!Windows.TryGetValue(deviceId, out var window))
        {
            window = new AgentsWindow(new AgentsWindowModel(app, deviceId, plugin, pane));
            Windows[deviceId] = window;
            window.Closed += (_, _) => Windows.Remove(deviceId);
        }
        else if (pane is not null)
        {
            window.Model.Selection = pane;
        }
        window.Show();
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
        if (startAgent)
        {
            window.StartAgent();
        }
    }

    // Closes all agents windows, when the app quits.
    public static void CloseAll()
    {
        foreach (var w in Windows.Values.ToArray())
        {
            w.Close();
        }
    }
}

// The window of the herdr agents of 1 computer: the agents on the left, and
// the thread of the selected agent on the right. Escape closes it. Ctrl+R
// reads the output again, and Ctrl+D shows the changes.
public sealed class AgentsWindow : Window
{
    readonly AgentsView view;

    public AgentsWindowModel Model { get; }

    // The dialog that starts an agent, while it shows. Tests read it.
    internal NewAgentDialog? NewAgent { get; private set; }

    public AgentsWindow(AgentsWindowModel model)
    {
        Model = model;
        Title = $"Agents on {model.Name}";
        Width = 900;
        Height = 620;
        MinWidth = 640;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        view = new AgentsView(this);
        Content = view;
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
        Tn.Changed += Retheme;
        Closed += (_, _) =>
        {
            Tn.Changed -= Retheme;
            NewAgent?.Close();
            view.Close();
        };
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
        InputBindings.Add(new KeyBinding(new Relay(() => view.Detail?.Refresh()), Key.R, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(() => view.Detail?.ShowChanges()), Key.D, ModifierKeys.Control));
    }

    void Retheme()
    {
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
    }

    // The view of the window. Tests read it.
    internal AgentsView View => view;

    // Opens the dialog that starts an agent, or brings it to the front.
    public void StartAgent()
    {
        if (NewAgent is { IsLoaded: true } open)
        {
            open.Activate();
            return;
        }
        NewAgent = new NewAgentDialog(Model) { Owner = this };
        NewAgent.Closed += (_, _) => NewAgent = null;
        NewAgent.Show();
    }
}

// The content of an agents window: the herdr agents of a computer on the
// left, and the thread of the selected agent on the right. The agents that
// need input come first. A computer with more than 1 herdr session shows the
// sessions as pills at the top, and the list has the agents of the picked
// session. AgentsView.swift of the Mac app has the same layout.
public sealed class AgentsView : View
{
    readonly AgentsWindow window;
    readonly Grid split = new();
    readonly Border listHost = new();
    readonly ContentControl detailHost = new() { Focusable = false };
    // The list keeps its scroll position across the drawings.
    readonly ScrollViewer listScroll = Ui.Scroll(new Border());
    bool online;

    public AgentsView(AgentsWindow window)
    {
        this.window = window;
        Watch(Model.App);
        Watch(Model.Plugin.Model);
        Watch(Model);
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260), MinWidth = 220, MaxWidth = 360 });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 400 });
        var splitter = new GridSplitter { Width = 1, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeBehavior = GridResizeBehavior.PreviousAndNext };
        Grid.SetColumn(splitter, 1);
        Grid.SetColumn(detailHost, 2);
        split.Children.Add(listHost);
        split.Children.Add(splitter);
        split.Children.Add(detailHost);
    }

    AgentsWindowModel Model => window.Model;

    // The thread of the selected agent, or null.
    internal AgentDetail? Detail { get; private set; }

    // Ends the watch of the agent on screen, when the window closes.
    public void Close()
    {
        Detail?.Close();
        Detail = null;
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var device = Model.Device;
        var name = Model.Name;
        var isOnline = device?.Online == true;
        // The window asks for the agents each time that the computer comes online.
        if (isOnline && !online)
        {
            Model.Plugin.Request(Model.DeviceId);
        }
        online = isOnline;
        // An open thread stays while the computer is away. It shows the last output and a note, see AgentDetail.
        if (!isOnline && (Detail is null || Model.Shown is null))
        {
            return Parts.Unavailable(Icons.Wifi, $"{name} is offline", $"The agents show when {name} is on the same network.");
        }
        if (Model.Shown is not { } herdr)
        {
            return Ui.H(10, Parts.Spinner(), Ui.Text($"Loading the agents of {name}…", 13, color: tn.Sub))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        var layout = new DockPanel();
        if (Model.Herdr is { Sessions.Count: > 1 } all && Model.Plugin.Model.Session(Model.DeviceId) is { } shown)
        {
            var pills = AgentsFeature.SessionPills(all, shown, null, session =>
            {
                Model.Plugin.Model.SelectSession(Model.DeviceId, session);
                Model.Selection = Model.Shown?.Sorted.FirstOrDefault()?.Pane;
            });
            var top = Ui.V(0, Ui.Box(pills, 12, 4, 12, 4), new Border { Height = 1, Background = tn.Line });
            DockPanel.SetDock(top, Dock.Top);
            layout.Children.Add(top);
        }
        var body = Body(herdr, name);
        if (layout.Children.Count == 0)
        {
            return body;
        }
        Ui.Detach(body);
        layout.Children.Add(body);
        return layout;
    }

    UIElement Body(HerdrState herdr, string name)
    {
        if (!herdr.Enabled)
        {
            return Unavailable("Agent status is off", $"On {name}, set herdr = true in ~/.config/flux/config.toml. Then run systemctl --user reload fluxd.");
        }
        if (!herdr.Running)
        {
            return Unavailable("herdr is not running", $"Start herdr on {name}. Its coding agents show here.");
        }
        if (herdr.Agents.Count == 0)
        {
            return Unavailable("No agents yet", $"Start a coding agent from here, or in a herdr pane on {name}.", start: true);
        }
        var agents = herdr.Sorted;
        if (Model.Selection is null)
        {
            Model.Selection = agents[0].Pane;
        }
        listHost.Child = List(agents);
        var pane = Model.Selection;
        if (Detail?.Pane != pane)
        {
            Detail?.Close();
            Detail = pane is null ? null : new AgentDetail(Model, pane);
        }
        detailHost.Content = Detail is not null ? Detail
            : Parts.Unavailable(AgentGlyphs.Agent, "Select an agent", "Its thread shows here.");
        return split;
    }

    UIElement Unavailable(string title, string text, bool start = false)
    {
        Detail?.Close();
        Detail = null;
        var buttons = Ui.H(8,
            start ? new FluxButton("Start an agent", ButtonKind.Filled, window.StartAgent).Named("Start an agent") : null,
            new FluxButton("Refresh", ButtonKind.Outlined, () => Model.Plugin.Request(Model.DeviceId)).Named("Refresh").Help("Read the agent list again"));
        buttons.HorizontalAlignment = HorizontalAlignment.Center;
        return Ui.V(12, Parts.Unavailable(AgentGlyphs.Agent, title, text), buttons).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    // The agents of the computer, with Start an agent and Refresh at the bottom.
    UIElement List(IReadOnlyList<HerdrAgent> agents)
    {
        var tn = Tn.Current;
        var rows = agents.Select(a => (UIElement)Row(a, a.Pane == Model.Selection)).ToArray();
        var bottom = Ui.H(4,
            Ui.Text(agents.Count == 1 ? "1 agent" : $"{agents.Count} agents", 11, color: tn.Sub).Fill(),
            new FluxButton("", ButtonKind.Text, window.StartAgent, Icons.Add).Named("Start an agent").Help("Start an agent"),
            new FluxButton("", ButtonKind.Text, () => Model.Plugin.Request(Model.DeviceId), Icons.Refresh).Named("Refresh the agent list")
                .Help("Refresh the agent list")).Margin(12, 6, 8, 6);
        var dock = new DockPanel { Background = tn.Bg };
        DockPanel.SetDock(bottom, Dock.Bottom);
        dock.Children.Add(bottom);
        listScroll.Content = Ui.V(2, rows).Margin(8, 8, 8, 8);
        Ui.Detach(listScroll);
        dock.Children.Add(listScroll);
        return new Border { Child = dock, BorderBrush = tn.Line, BorderThickness = new Thickness(0, 0, 1, 0) };
    }

    // 1 agent in the list: its status, agent, project, workspace, and title.
    UIElement Row(HerdrAgent agent, bool selected)
    {
        var tn = Tn.Current;
        var project = agent.Project.Length == 0 ? agent.Pane : agent.Project;
        var top = Ui.H(6, AgentParts.PulseDot(agent.Status.Ink(), 7, false), Ui.Text(agent.Status.Label(), 11, FontWeights.Medium, agent.Status.Ink()),
            Ui.Spacer(6), Ui.Text(agent.Agent, 11, color: tn.Sub, mono: true));
        var middle = Ui.H(6, Ui.Text(project, 13, FontWeights.SemiBold),
            agent.Workspace.Length > 0 && agent.Workspace != agent.Project ? Ui.Text(agent.Workspace, 11, color: tn.Sub, mono: true).Fill() : null);
        var body = Ui.V(3, top, middle, Ui.Text(agent.Title.Length == 0 ? agent.Pane : agent.Title, 11, color: tn.Sub));
        var tile = new Border
        {
            Child = body,
            Background = selected ? tn.Line : System.Windows.Media.Brushes.Transparent,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(10, 7, 10, 7),
            MinHeight = Metrics.RowHeight,
        };
        var button = new PlainButton(tile, () => Model.Selection = agent.Pane).Named($"{agent.Status.Label()}, {project}, {agent.Agent}");
        System.Windows.Automation.AutomationProperties.SetItemStatus(button, selected ? "Selected" : "");
        return button;
    }
}

// An answer that the window sent, for the thread: Text shows as a bubble of
// the user with Meta under it, after the block After. The output of the
// agent does not show an answer to a dialog, so the window keeps it while
// the agent works on it.
public sealed record SentAnswer(string Text, string Meta, ThreadBlock? After, bool Working = false);

// 1 agent as a thread: its output as messages, tool calls, and changes,
// with the newest at the bottom, and the dock under it. The dock shows the
// question of a blocked agent with its choices, the step of a working agent
// with Interrupt, or the end of a turn, and the composer. HerdrPlugin.Watch
// reads the output when the status changes, and every 5 seconds while the
// agent works. In the chat of an agent in the main window, the header is the
// top bar of a chat. AgentDetail of the Mac app has the same parts.
public sealed class AgentDetail : View
{
    // How close to the end the thread must be, in px, to follow new blocks.
    const double FollowSlack = 48;

    readonly AgentsWindowModel model;
    // True in the chat of the agent in the main window.
    readonly bool chat;
    readonly ScrollViewer scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    readonly ReplyControls controls;
    readonly FirstTaskNote taskNote;
    // The layout stays across the drawings, so that the reply field keeps
    // its place and its focus, and the thread keeps its scroll position.
    readonly DockPanel root = new();
    readonly Border headerHost = new();
    readonly Border lineHost = new();
    readonly Border taskHost = new();
    readonly Border noteHost = new();
    readonly Border noControl = new() { CornerRadius = new CornerRadius(20, 20, 0, 0), Padding = new Thickness(16) };
    readonly Grid threadHost = new();
    readonly Border placeholder = new();
    // The tool calls that the user opened or closed, by the key of the row.
    readonly Dictionary<string, bool> opened = [];
    // What the thread on screen shows. The thread draws again only when it changes.
    (ValueList<TermLine> Lines, string? Error, bool Truncated, SentAnswer? Sent, AgentStatus Status, int Opened, ThemeColors Theme, bool Review)? shownThread;
    int openedVersion;
    bool keysOpen;
    bool follow = true;
    bool closed;
    SentAnswer? sent;
    AgentStatus? lastStatus;
    // The last output of the agent, for the thread while the changes show.
    HerdrOutput? lastAnsi;
    string lastText = "";
    ValueList<TermLine>? parsed;
    AgentThread? thread;
    AgentAsk? ask;
    ChangesWindow? changes;

    public AgentDetail(AgentsWindowModel model, string pane, bool chat = false)
    {
        this.model = model;
        this.chat = chat;
        Pane = pane;
        controls = new ReplyControls(model, pane, this);
        taskNote = new FirstTaskNote(model, pane, controls.Fill);
        DockPanel.SetDock(headerHost, Dock.Top);
        DockPanel.SetDock(lineHost, Dock.Top);
        DockPanel.SetDock(noteHost, Dock.Top);
        var bottom = Ui.V(0, taskHost, controls, noControl);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(headerHost);
        root.Children.Add(lineHost);
        root.Children.Add(noteHost);
        root.Children.Add(bottom);
        threadHost.Children.Add(placeholder);
        threadHost.Children.Add(scroll);
        root.Children.Add(threadHost);
        Watch(model.App);
        Watch(model.Plugin.Model);
        scroll.ScrollChanged += (_, e) =>
        {
            if (e.ExtentHeightChange != 0)
            {
                return;
            }
            var next = scroll.VerticalOffset >= scroll.ScrollableHeight - FollowSlack;
            if (next != follow)
            {
                follow = next;
                Invalidate();
            }
        };
        model.Plugin.Watch(model.DeviceId, pane);
    }

    public string Pane { get; }

    HerdrAgent? Agent => model.Herdr?.Agent(Pane);

    bool CanReview => Agent is not null && model.Herdr?.Review == true && model.Device?.Online == true;

    // True while the keys Esc, Tab, Up, Down, and Enter show.
    public bool KeysOpen
    {
        get => keysOpen;
        set
        {
            keysOpen = value;
            Invalidate();
        }
    }

    // Keeps an answer for the thread, see SentAnswer.
    public void Answered(SentAnswer answer)
    {
        sent = answer;
        Invalidate();
    }

    // Ends the watch and forgets the output, when the detail leaves the window.
    public void Close()
    {
        if (closed)
        {
            return;
        }
        closed = true;
        changes?.Close();
        // The field of the reply is gone, so the words of a dictation have no place.
        controls.Voice.Dictation.Cancel();
        model.Plugin.Unwatch(model.DeviceId, Pane);
    }

    // Reads the output again.
    public void Refresh()
    {
        if (Agent is not null)
        {
            model.Plugin.Read(model.DeviceId, Pane);
        }
    }

    // Shows the changes of the repository of the agent. The output then
    // holds the diff until the changes close.
    public void ShowChanges()
    {
        if (!CanReview)
        {
            return;
        }
        if (changes is not null)
        {
            changes.Activate();
            return;
        }
        changes = new ChangesWindow(model, Pane) { Owner = Window.GetWindow(this) };
        changes.Closed += (_, _) =>
        {
            changes = null;
            if (!closed)
            {
                model.Plugin.Watch(model.DeviceId, Pane, false);
            }
            Invalidate();
        };
        model.Plugin.Watch(model.DeviceId, Pane, true);
        changes.Show();
    }

    // The changes window, while it shows. Tests read it.
    internal ChangesWindow? Changes => changes;

    // The dock with the reply field. Tests read it.
    internal ReplyControls Controls => controls;

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var agent = Agent;
        var read = model.Plugin.Model.Output(model.DeviceId, Pane);
        // While the changes show, the output holds the diff, so the thread keeps the last output of the agent.
        var ansi = read is not null && read.View != "diff" && !(changes is not null && read.Loading && read.Lines.Count == 0) ? read : null;
        if (ansi is not null)
        {
            lastAnsi = ansi;
        }
        var output = ansi ?? lastAnsi;
        // A read in progress keeps the lines, so only new lines parse again.
        if (!ReferenceEquals(output?.Lines, parsed))
        {
            parsed = output?.Lines;
            var texts = output?.Lines.Select(l => l.Text).ToArray();
            thread = texts is null ? null : AgentThread.Parse(texts);
            ask = texts is null ? null : AgentAsk.Find(texts, 6);
        }
        // The answer shows while the agent works on it.
        if (agent?.Status != lastStatus)
        {
            lastStatus = agent?.Status;
            if (sent is not null)
            {
                sent = agent?.Status == AgentStatus.Working ? sent with { Working = true } : sent.Working ? null : sent;
            }
        }
        if (agent is null)
        {
            return Parts.Unavailable(AgentGlyphs.Agent, "The agent is gone", $"The agent in {Pane} on {model.Name} stopped or moved to another pane.");
        }
        var control = model.Herdr?.Control == true;
        root.Background = tn.Bg;
        headerHost.Child = chat ? ChatBar(agent, output) : Header(agent, output);
        // The line moves while the agent works. It stays while the status
        // and the theme stay, so that its motion does not start again.
        if (!(lineHost.Tag is (AgentStatus shownStatus, ThemeColors shownTheme) && shownStatus == agent.Status && shownTheme == tn))
        {
            lineHost.Child = AgentParts.ProgressLine(agent.Status == AgentStatus.Working);
            lineHost.Tag = (agent.Status, tn);
        }
        taskHost.Child = taskNote.Build(agent);
        // The keys and the field take no click while the computer is not reachable.
        var online = model.Device?.Online == true;
        controls.Shown(control && online);
        noControl.Shown(!control);
        noControl.Background = tn.Tile;
        noControl.Child = Ui.Text($"To answer from this computer, turn on Agent control in Flux on {model.Name}, on the Access card.", 12, color: tn.Sub, wrap: true);
        var note = online ? null : LinkNote.ThreadNote(false, model.App.Connecting, model.Name, model.Plugin.Model.OutputAt(model.DeviceId, Pane),
            DateTimeOffset.Now, Texts.ClockTime);
        noteHost.Shown(note is not null);
        noteHost.Child = note is null ? null : LinkNoteView(note);
        if (control && online)
        {
            controls.Show(agent, output, thread, ask, CanReview ? ShowChanges : null);
        }
        ThreadList(output, agent.Status);
        return root;
    }

    // The note about the link above the thread: that the computer is not
    // reachable and when the output is from, with Retry, or that Flux connects to it.
    UIElement LinkNoteView(ThreadNote note)
    {
        var tn = Tn.Current;
        var text = note.Detail.Length == 0 ? note.Title : $"{note.Title} {note.Detail}";
        var mark = note.State == ThreadLink.Connecting ? Parts.Spinner() : Parts.LinkDot(false);
        UIElement? retry = note.State == ThreadLink.Unreachable ? new FluxButton("Retry", ButtonKind.Text, model.App.Retry).Named("Retry") : null;
        var row = Ui.H(10, Ui.Box(mark, 0, 0, 0, 0).Width(18), Ui.Text(text, 12, color: tn.Sub, wrap: true).Fill(), retry);
        return Ui.Box(row, Metrics.Gutter, 6, Metrics.Gutter, 6);
    }

    // The header: the status, the task, the agent and the pane, then
    // Changes, Keys, Copy, and Refresh.
    UIElement Header(HerdrAgent agent, HerdrOutput? output)
    {
        var tn = Tn.Current;
        var title = agent.Title.Length > 0 ? agent.Title : agent.Project.Length > 0 ? agent.Project : agent.Pane;
        var text = output?.Text ?? "";
        var loading = output is { Loading: true, Lines.Count: > 0 };
        var control = model.Herdr?.Control == true;
        var titles = Ui.V(2,
            Ui.Text(title, 15, FontWeights.SemiBold),
            Ui.Text($"{agent.Agent} · {agent.Pane} · {agent.Status.Label()}", 11, color: tn.Sub, mono: true)).Fill();
        System.Windows.Automation.AutomationProperties.SetHeadingLevel(titles, System.Windows.Automation.AutomationHeadingLevel.Level1);
        var copy = new FluxButton("", ButtonKind.Text, () => Clipboard.SetText(text), Icons.Copy, enabled: text.Length > 0)
            .Named("Copy the output").Help("Copy the output");
        UIElement refresh = loading ? Parts.Spinner(14).Margin(8, 0, 8, 0)
            : new FluxButton("", ButtonKind.Text, Refresh, Icons.Refresh).Named("Refresh").Help("Read the output again (Ctrl+R)");
        var row = Ui.H(12,
            AgentParts.StatusMark(agent.Status),
            titles,
            CanReview ? new FluxButton("Changes", ButtonKind.Outlined, ShowChanges).Named("Changes").Help("Show the changes of the repository (Ctrl+D)") : null,
            control ? KeysToggle() : null,
            copy,
            refresh);
        return Ui.Box(row, 16, 12, 16, 12);
    }

    // The top bar of the chat of the agent: the picture with the state dot,
    // the task, the agent, the project, and the computer in mono, then
    // Changes, Keys, Copy, and Refresh.
    UIElement ChatBar(HerdrAgent agent, HerdrOutput? output)
    {
        var tn = Tn.Current;
        var title = agent.Title.Length > 0 ? agent.Title : agent.Project.Length > 0 ? agent.Project : agent.Pane;
        var context = Texts.ContextLine(agent.Agent, agent.Project.Length > 0 ? agent.Project : agent.Workspace, model.Name);
        var text = output?.Text ?? "";
        var loading = output is { Loading: true, Lines.Count: > 0 };
        var dot = agent.Status switch
        {
            AgentStatus.Blocked => tn.Red,
            AgentStatus.Done => tn.Green,
            AgentStatus.Working => null,
            _ => tn.Dim,
        };
        var picture = ChatParts.Picture(AgentGlyphs.Agent, tn.Accent, tn.AccentTile, null, tn.Bg, dot, agent.Status == AgentStatus.Working)
            .Named(agent.Status.Label());
        var changesKey = CanReview
            ? new FluxButton("±", ButtonKind.Text, ShowChanges).Named("Changes").Help("Show the changes of the repository (Ctrl+D)")
            : null;
        var copy = new FluxButton("", ButtonKind.Text, () => Clipboard.SetText(text), Icons.Copy, enabled: text.Length > 0)
            .Named("Copy the output").Help("Copy the output");
        UIElement refresh = loading ? Parts.Spinner(14).Margin(8, 0, 8, 0)
            : new FluxButton("", ButtonKind.Text, Refresh, Icons.Refresh).Named("Refresh").Help("Read the output again (Ctrl+R)");
        return ChatParts.Bar(picture, title, context, changesKey, model.Herdr?.Control == true ? KeysToggle() : null, copy, refresh);
    }

    // The Keys toggle of the header, with the accent while the keys show.
    UIElement KeysToggle()
    {
        var b = new FluxButton("Keys", keysOpen ? ButtonKind.Tonal : ButtonKind.Outlined, () => KeysOpen = !keysOpen, Icons.Keyboard)
            .Named("Keys").Help("Show the keys Esc, Tab, Up, Down, and Enter");
        System.Windows.Automation.AutomationProperties.SetItemStatus(b, keysOpen ? "On" : "Off");
        return b;
    }

    // The thread: the blocks with the newest at the bottom, the line that
    // the agent waits for the user or finished, and the sent answer. The
    // view follows new blocks at the end. When the user scrolls up to read
    // older blocks, the view stays there, and a button goes back to the
    // newest blocks.
    void ThreadList(HerdrOutput? output, AgentStatus status)
    {
        var tn = Tn.Current;
        // The button that goes back to the newest lines, over the thread.
        foreach (var old in threadHost.Children.OfType<PlainButton>().ToArray())
        {
            threadHost.Children.Remove(old);
        }
        if (output is null || output.Loading && output.Lines.Count == 0)
        {
            shownThread = null;
            Placeholder(AgentParts.Skeleton([0.62, 0.9, 0.48, 0.84, 0.7, 0.36], "Reading the output").Margin(16).Top());
            return;
        }
        if (output.Error is { } error && output.Lines.Count == 0)
        {
            shownThread = null;
            Placeholder(Parts.Unavailable(Icons.Warning, "No output", error));
            return;
        }
        placeholder.Child = null;
        scroll.Visibility = Visibility.Visible;
        DownButton(output);
        // A large output takes time to draw, so the thread draws again only when what it shows changed.
        var shows = (output.Lines, output.Error, output.Truncated, sent, status, openedVersion, tn, CanReview);
        if (shownThread is { } last && ReferenceEquals(last.Lines, output.Lines) && last.Error == output.Error && last.Truncated == output.Truncated &&
            last.Sent == sent && last.Status == status && last.Opened == openedVersion && last.Theme == tn && last.Review == CanReview)
        {
            return;
        }
        shownThread = shows;
        var blocks = thread?.Blocks ?? ValueList<ThreadBlock>.Empty;
        // The place of the sent answer: after its block, at the start
        // without one, or at the end when the block left the output.
        var at = sent is null ? -2 : sent.After is null ? -1 : LastIndex(blocks, sent.After) is var i && i >= 0 ? i : blocks.Count - 1;
        var items = new List<UIElement?>();
        if (output.Truncated)
        {
            items.Add(Ui.Text("Older lines are cut.", 11, color: tn.Sub, mono: true));
        }
        if (output.Error is { } problem)
        {
            items.Add(Ui.Text(problem, 12, color: tn.Red, wrap: true));
        }
        if (blocks.Count == 0 && sent is null)
        {
            items.Add(Ui.Text("No output yet.", 12, color: tn.Sub, mono: true));
        }
        if (at == -1 && sent is not null)
        {
            items.Add(ThreadViews.You(sent.Text, sent.Meta));
        }
        var seen = new Dictionary<string, int>();
        for (var n = 0; n < blocks.Count; n++)
        {
            var key = RowKey(blocks[n], seen);
            items.Add(Block(key, blocks[n], n, n == blocks.Count - 1, output, status));
            if (n == at && sent is not null)
            {
                items.Add(ThreadViews.You(sent.Text, sent.Meta));
            }
        }
        if (status == AgentStatus.Blocked)
        {
            items.Add(ThreadViews.Waiting());
        }
        if (status == AgentStatus.Done)
        {
            items.Add(ThreadViews.Done(thread?.Worked ?? ""));
        }
        scroll.Content = Ui.V(12, items).Margin(16, 16, 16, 12);
        // New output scrolls to the newest blocks, unless the user reads older ones.
        if (output.Text != lastText)
        {
            lastText = output.Text;
            if (follow)
            {
                Dispatcher.BeginInvoke(DispatcherPriority.Loaded, scroll.ScrollToEnd);
            }
        }
    }

    // The button that goes back to the newest lines, while the user reads older ones.
    void DownButton(HerdrOutput output)
    {
        var tn = Tn.Current;
        if (!follow && output.Lines.Count > 0)
        {
            var down = new PlainButton(new Border
            {
                Child = Ui.Icon(AgentGlyphs.ArrowDown, 13, tn.Accent),
                Width = 32,
                Height = 32,
                CornerRadius = new CornerRadius(16),
                Background = tn.TileHi,
                BorderBrush = tn.Line,
                BorderThickness = new Thickness(1),
            }, () =>
            {
                follow = true;
                scroll.ScrollToEnd();
                Invalidate();
            }).Named("Show the newest lines").Help("Show the newest lines");
            down.HorizontalAlignment = HorizontalAlignment.Right;
            down.VerticalAlignment = VerticalAlignment.Bottom;
            down.Margin = new Thickness(12);
            threadHost.Children.Add(down);
        }
    }

    // Shows a line or a message in the place of the thread.
    void Placeholder(UIElement content)
    {
        Ui.Detach(content);
        placeholder.Child = content;
        scroll.Visibility = Visibility.Collapsed;
    }

    static int LastIndex(IReadOnlyList<ThreadBlock> blocks, ThreadBlock block)
    {
        for (var i = blocks.Count - 1; i >= 0; i--)
        {
            if (blocks[i] == block)
            {
                return i;
            }
        }
        return -1;
    }

    // A key of a block that stays the same while the output grows: the head
    // of the block and its number among the same heads.
    static string RowKey(ThreadBlock block, Dictionary<string, int> seen)
    {
        var head = block switch
        {
            ThreadBlock.Tool t => $"tool:{t.Call.Name}({t.Call.Args})",
            ThreadBlock.Message m => "message:" + m.Text[..Math.Min(40, m.Text.Length)],
            ThreadBlock.Prompt p => "prompt:" + p.Text[..Math.Min(40, p.Text.Length)],
            ThreadBlock.Changes c => "changes:" + string.Join(",", c.Files.Files.Select(f => f.Path)),
            ThreadBlock.Raw r => $"raw:{r.From}",
            _ => "block",
        };
        var n = seen.GetValueOrDefault(head) + 1;
        seen[head] = n;
        return $"{head}#{n}";
    }

    UIElement Block(string key, ThreadBlock block, int index, bool last, HerdrOutput output, AgentStatus status)
    {
        switch (block)
        {
            case ThreadBlock.Message m:
                return ThreadViews.Message(m.Text);
            case ThreadBlock.Tool t:
                var running = status == AgentStatus.Working && last;
                var open = opened.TryGetValue(key, out var o) ? o : running;
                return ThreadViews.Tool(t.Call, running, open, () =>
                {
                    opened[key] = !open;
                    openedVersion++;
                    Invalidate();
                });
            case ThreadBlock.Changes c:
                return ThreadViews.Changes(c.Files, CanReview ? ShowChanges : null);
            case ThreadBlock.Prompt p:
                return ThreadViews.You(p.Text);
            case ThreadBlock.Raw r:
                var from = Math.Min(r.From, output.Lines.Count);
                var to = Math.Min(Math.Max(r.To, from), output.Lines.Count);
                var raw = output.Lines.Skip(from).Take(to - from).ToArray();
                // The first block can be the end of a block whose start is
                // older than the read. A long one folds, unless it is the only
                // block, for example the output of an agent that the thread
                // does not read.
                if (index == 0 && !last && raw.Length > ThreadViews.EarlierFoldLines)
                {
                    var earlier = opened.GetValueOrDefault("earlier");
                    return ThreadViews.Earlier(raw, earlier, () =>
                    {
                        opened["earlier"] = !earlier;
                        openedVersion++;
                        Invalidate();
                    });
                }
                return ThreadViews.Raw(raw);
            default:
                return new Border();
        }
    }
}

// The changes of the repository of an agent: each file with its counts and
// its diff lines in color. Escape closes the window. ChangesSheet of the Mac
// app has the same parts.
public sealed class ChangesWindow : Window
{
    public ChangesWindow(AgentsWindowModel model, string pane)
    {
        Title = "Changes";
        Width = 720;
        Height = 640;
        MinWidth = 560;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        FontFamily = Faces.Body;
        Background = Tn.Current.Tile;
        Content = new ChangesView(model, pane, Close);
        Tn.Changed += Retheme;
        Closed += (_, _) => Tn.Changed -= Retheme;
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
    }

    void Retheme() => Background = Tn.Current.Tile;

    sealed class ChangesView : View
    {
        readonly AgentsWindowModel model;
        readonly string pane;
        readonly Action close;

        public ChangesView(AgentsWindowModel model, string pane, Action close)
        {
            this.model = model;
            this.pane = pane;
            this.close = close;
            Watch(model.Plugin.Model);
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            var read = model.Plugin.Model.Output(model.DeviceId, pane);
            var diff = read is { View: "diff" } ? read : null;
            // The files show once the diff came. They are null while it loads.
            var files = diff is not null && (!diff.Loading || diff.Lines.Count > 0) ? DiffFile.Parse(diff.Lines.Select(l => l.Text).ToArray()) : null;
            var problem = diff?.Error ?? diff?.Lines.FirstOrDefault()?.Text;
            var head = Ui.H(8,
                Ui.Text("Changes", 15, FontWeights.SemiBold).Fill(),
                files is { Count: > 0 } ? Ui.Text($"+{files.Sum(f => f.Added)}", 12, color: tn.Green, mono: true) : null,
                files is { Count: > 0 } ? Ui.Text($"−{files.Sum(f => f.Removed)}", 12, color: tn.Red, mono: true) : null,
                new FluxButton("Close", ButtonKind.Outlined, close).Named("Close").Help("Close the changes (Esc)")).Margin(16, 12, 16, 12);
            System.Windows.Automation.AutomationProperties.SetHeadingLevel(head.Children[0], System.Windows.Automation.AutomationHeadingLevel.Level1);
            var items = new List<UIElement?>();
            if (files is null)
            {
                items.Add(AgentParts.Skeleton([0.7, 0.9, 0.5, 0.8], "Reading the changes"));
            }
            else if (files.Count == 0)
            {
                items.Add(Ui.Text(problem ?? "No changes in this repository.", 13, color: tn.Sub, wrap: true));
            }
            else
            {
                if (diff?.Truncated == true)
                {
                    items.Add(Ui.Text("The diff is longer than the preview limit. Older files are cut.", 12, color: tn.Sub, wrap: true));
                }
                items.AddRange(files.Select(ThreadViews.DiffCard));
            }
            var layout = new DockPanel();
            DockPanel.SetDock(head, Dock.Top);
            layout.Children.Add(head);
            layout.Children.Add(Ui.Scroll(Ui.V(10, items).Margin(12, 0, 12, 16)));
            return layout;
        }
    }
}
