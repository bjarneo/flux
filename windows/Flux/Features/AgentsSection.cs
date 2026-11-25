using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The herdr agents in the app: the agents of Control, the notification
// settings, the menu item of the tray, Start Agent in the chats, and the
// start hook. AgentsSection.swift and ControlView.swift of the Mac app have
// the same parts.
public static class AgentsFeature
{
    static readonly ConditionalWeakTable<AppModel, AgentList> Lists = new();

    // The dialog that starts an agent from the chats, while it shows.
    static NewAgentDialog? starting;

    // A click on an agent notification opens the chat of that agent. The
    // Inbox keeps its times and its prompts while the app runs.
    public static void DidLaunch(AppModel model)
    {
        if (model.Core.Plugin<HerdrPlugin>() is { } herdr)
        {
            herdr.Model.Open = (id, pane) =>
            {
                model.OpenChat(new ChatKey.Agent(id, pane));
                model.ShowMain?.Invoke();
            };
        }
        model.WatchEvents();
        ReplyLock.Watch();
        // An answer from a notification needs the unlock of Windows Hello, as a reply in the thread does.
        if (model.Core.Plugin<HerdrPlugin>() is { } plugin)
        {
            plugin.Unlock = (reason, action, onError, onCancel) =>
            {
                // The app can sit hidden in the tray. Show it, so that the prompt of Windows Hello has a visible owner.
                if (!ReplyLock.IsUnlocked)
                {
                    model.ShowMain?.Invoke();
                }
                ReplyLock.Run(reason, Application.Current?.MainWindow, action, onError, onCancel);
            };
        }
    }

    // True when the computer lets this computer start an agent: herdr runs
    // there with herdr_control = true.
    public static bool CanStart(AppModel model, DeviceSnapshot d) =>
        d.Accepts(PacketType.Herdr) && model.Core.Plugin<HerdrPlugin>()?.Model.States.GetValueOrDefault(d.Id) is { Running: true, Control: true };

    // Opens the dialog that starts an agent on the computer, over the main
    // window. The new agent opens in its chat when the computer reports it.
    public static void Start(AppModel model, string deviceId)
    {
        if (model.Core.Plugin<HerdrPlugin>() is not { } plugin)
        {
            return;
        }
        if (starting is { IsLoaded: true } open)
        {
            open.Activate();
            return;
        }
        var m = new AgentsWindowModel(model, deviceId, plugin, null);
        m.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AgentsWindowModel.Selection) && m.Selection is { } pane)
            {
                model.OpenChat(new ChatKey.Agent(deviceId, pane));
            }
        };
        starting = new NewAgentDialog(m) { Owner = Application.Current?.MainWindow };
        starting.Closed += (_, _) => starting = null;
        starting.Show();
    }

    // The + key of the chats: starts an agent on the only online computer
    // that allows it, or on the computer that the user picks.
    public static void StartAnywhere(AppModel model)
    {
        var ready = model.ConnectedPaired.Where(d => CanStart(model, d)).ToArray();
        if (Targets.Among(model, ready, "No computer lets this computer start an agent. Turn on Agent control in Flux on a computer, on the Access card.") is { } id)
        {
            Start(model, id);
        }
    }

    // Agent in the tray of the chat of a computer that allows it.
    public static (string Title, string Glyph, Action Run)? DockTool(AppModel model, DeviceSnapshot d) =>
        CanStart(model, d) ? ("Agent", AgentGlyphs.Agent, () => Start(model, d.Id)) : null;

    // The agents and the terminals of the computers in scope, with the
    // agents that need the user first, for Control.
    public static UIElement? ControlSection(AppModel model)
    {
        if (model.Core.Plugin<HerdrPlugin>() is null)
        {
            return null;
        }
        var noPairing = model.Paired.Count == 0;
        if (!noPairing && !FluxKit.Inbox.HasFeature(model.Scope, model.State.Devices, d => d.Accepts(PacketType.Herdr)))
        {
            return null;
        }
        var list = Lists.GetValue(model, m => new AgentList(m));
        list.Redraw();
        return list;
    }

    // The agent notification switches. They apply to all computers.
    public static (string Label, UIElement Content)? Settings(AppModel model)
    {
        if (model.Core.Plugin<HerdrPlugin>() is not { } herdr)
        {
            return null;
        }
        var m = herdr.Model;
        return ("herdr agents", SettingsView.Group(
            SettingsView.Toggle("Agent needs input", m.InputAlerts, on => m.InputAlerts = on),
            SettingsView.Toggle("Agent finished", m.DoneAlerts, on => m.DoneAlerts = on),
            SettingsView.Note("Notifications when a coding agent in herdr on a computer waits for an answer, or finishes its work. They apply to all computers.")));
    }

    // The tray menu item that opens the agents of a computer.
    public static (string Title, Action Run)? TrayAction(AppModel model, DeviceSnapshot d)
    {
        if (model.Core.Plugin<HerdrPlugin>() is not { } herdr || !d.Accepts(PacketType.Herdr))
        {
            return null;
        }
        var blocked = herdr.Model.States.GetValueOrDefault(d.Id)?.Blocked ?? 0;
        return (blocked > 0 ? $"Agents ({blocked} {(blocked == 1 ? "needs" : "need")} input)…" : "Agents…", () => AgentsWindows.Show(model, d.Id));
    }

    // The herdr sessions of a computer as pills. The pill of the shown
    // session has the accent, and each pill counts the agents of its
    // session that need the user. computer names the computer when the
    // list shows more than 1.
    public static UIElement SessionPills(HerdrState state, HerdrSession selected, string? computer, Action<string> select)
    {
        var tn = Tn.Current;
        var items = new List<UIElement?>();
        if (computer is not null)
        {
            items.Add(Ui.Text(computer, 11.5, FontWeights.Medium, tn.Sub));
        }
        foreach (var s in state.Sessions)
        {
            var n = state.BlockedCount(s.Name);
            var on = s.Name == selected.Name;
            var meta = n > 0 ? $"{n} {(n == 1 ? "needs" : "need")} you" : "";
            var chip = new Border
            {
                Child = Ui.H(6, n > 0 ? Ui.Dot(tn.Red, 7) : null, Ui.Text(s.Label, 12, FontWeights.SemiBold, on ? tn.Text : tn.Sub),
                    meta.Length > 0 ? Ui.Text(meta, 11, color: tn.Sub, mono: true) : null),
                Background = on ? tn.AccentTile : tn.Tile,
                BorderBrush = on ? tn.Accent : tn.Line,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(Metrics.ChipCorner),
                Padding = new Thickness(12, 0, 12, 0),
                MinHeight = Metrics.ButtonHeight,
            };
            var name = s.Name;
            var b = new PlainButton(chip, () => select(name)).Named($"Session {s.Label}" + (meta.Length > 0 ? $", {meta}" : ""))
                .Help($"Show the agents of the session {s.Label}");
            System.Windows.Automation.AutomationProperties.SetItemStatus(b, on ? "Selected" : "");
            items.Add(b);
        }
        return new ScrollViewer
        {
            Content = Ui.H(8, items).Margin(0, 4, 0, 4),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
    }

    // The order of the agents of Control: the agents that need the user,
    // then the agents that work, then the rest.
    static int Order(AgentStatus s) => s switch
    {
        AgentStatus.Blocked => 0,
        AgentStatus.Working => 1,
        AgentStatus.Done => 2,
        AgentStatus.Idle => 3,
        _ => 4,
    };

    // The agents of Control. The times of the agents move each second, so
    // the clock sets their texts while the list shows. A click on an agent
    // opens it in the agents window.
    sealed class AgentList : View
    {
        readonly AppModel model;
        readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
        // The time text of each card, with the status and its start.
        readonly List<(TextBlock Text, AgentStatus Status, DateTimeOffset? Since)> times = [];
        string asked = "";

        public AgentList(AppModel model)
        {
            this.model = model;
            Watch(model);
            Watch(model.Core.Plugin<HerdrPlugin>()?.Model);
            clock.Tick += (_, _) => Tick();
            Loaded += (_, _) => clock.Start();
            Unloaded += (_, _) => clock.Stop();
        }

        void Tick()
        {
            var now = DateTimeOffset.Now;
            foreach (var (text, status, since) in times)
            {
                text.Text = AgentTime.When(status, since, now);
            }
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            if (model.Core.Plugin<HerdrPlugin>() is not { } herdr)
            {
                return new Border();
            }
            var scope = model.Scope;
            var devices = model.ConnectedPaired.Where(d => (scope is null || d.Id == scope) && d.Accepts(PacketType.Herdr)).ToArray();
            // The agent lists come again when the computers in scope change.
            var ids = string.Join(",", devices.Select(d => d.Id));
            if (ids != asked)
            {
                asked = ids;
                foreach (var d in devices)
                {
                    herdr.Request(d.Id);
                }
            }
            var rows = devices.SelectMany(d => ((IEnumerable<HerdrAgent>?)herdr.Model.Scoped(d.Id)?.Agents ?? []).Select(a => (Device: d, Agent: a)))
                .OrderBy(r => Order(r.Agent.Status)).ToArray();
            var terms = devices.SelectMany(d => ((IEnumerable<HerdrTerminal>?)herdr.Model.Scoped(d.Id)?.Panes ?? []).Select(t => (Device: d, Terminal: t))).ToArray();
            var blocked = rows.Count(r => r.Agent.Status == AgentStatus.Blocked);
            var summary = rows.Length == 0 ? "" : Texts.ContextLine(
                $"{rows.Length} {(rows.Length == 1 ? "agent" : "agents")}",
                blocked > 0 ? $"{blocked} {(blocked == 1 ? "needs" : "need")} you" : "");
            var target = FluxKit.Inbox.Target(scope, model.State.Devices, d => d.Accepts(PacketType.Herdr));
            var canOpen = target is ActionTarget.One or ActionTarget.Ask;
            var links = Ui.H(12,
                new FluxButton("Start Agent", ButtonKind.Text, () => Open(true), enabled: canOpen).Named("Start Agent").Help("Start a coding agent on the computer"),
                new FluxButton("Agents Window", ButtonKind.Text, () => Open(false), enabled: canOpen).Named("Agents Window").Help("Open the agents of the computer in their own window"));
            var items = new List<UIElement?> { Parts.ListHeading("Agents", summary, links) };
            foreach (var d in devices)
            {
                if (herdr.Model.States.GetValueOrDefault(d.Id) is { Sessions.Count: > 1 } all && herdr.Model.Session(d.Id) is { } shown)
                {
                    var id = d.Id;
                    items.Add(SessionPills(all, shown, devices.Length > 1 ? d.Name : null, s => herdr.Model.SelectSession(id, s)));
                }
            }
            items.Add(Note(herdr, devices, rows.Length, terms.Length));
            times.Clear();
            foreach (var (d, a) in rows)
            {
                var since = herdr.Model.AgentSince(d.Id, a.Pane);
                var time = Ui.Text(AgentTime.When(a.Status, since, DateTimeOffset.Now), 10.5, color: tn.Sub, mono: true);
                times.Add((time, a.Status, since));
                items.Add(AgentCard(a, time, () => AgentsWindows.Show(model, d.Id, a.Pane)));
            }
            foreach (var (_, t) in terms)
            {
                items.Add(TerminalCard(t));
            }
            // Only the times of the agents change each second.
            if (rows.Any(r => r.Agent.Status is AgentStatus.Working or AgentStatus.Blocked or AgentStatus.Idle))
            {
                clock.Start();
            }
            else
            {
                clock.Stop();
            }
            return Ui.V(Metrics.Gap, items);
        }

        // Opens the agents window of the computer for the action, or asks which computer.
        void Open(bool start)
        {
            if (Targets.Pick(model, PacketType.Herdr) is { } id)
            {
                AgentsWindows.Show(model, id, startAgent: start);
            }
        }

        // The line under the heading that tells why no agent shows, or nothing.
        UIElement? Note(HerdrPlugin herdr, IReadOnlyList<DeviceSnapshot> devices, int rows, int terminals)
        {
            var single = devices.Count == 1 ? devices[0] : null;
            var state = single is null ? null : herdr.Model.Scoped(single.Id);
            if (devices.Count == 0)
            {
                var d = model.PairedDevice(model.Scope);
                return Line(d is null ? "No computer with herdr is online." : $"{d.Name} is not reachable. Its agents show when it connects.");
            }
            if (single is not null && state is null)
            {
                return AgentParts.Skeleton([0.7, 0.5], $"Loading the agents of {single.Name}").Margin(4);
            }
            if (single is not null && state?.Enabled == false)
            {
                return Line($"Agent status is off on {single.Name}. Set herdr = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.");
            }
            if (single is not null && state?.Running == false)
            {
                return Line($"herdr is not running on {single.Name}. Start herdr there, and its coding agents show here.");
            }
            if (rows == 0 && terminals == 0)
            {
                return Line("No agents run in herdr yet.");
            }
            return null;
        }

        static UIElement Line(string text) => Ui.Text(text, 12, color: Tn.Current.Sub, wrap: true).Margin(4);
    }

    // An agent: its status, the agent and the project in mono, and its task.
    // At the end, the time of its status as this computer saw it, and a
    // chevron. An agent that needs the user has a red border.
    static UIElement AgentCard(HerdrAgent agent, TextBlock when, Action open)
    {
        var tn = Tn.Current;
        var task = agent.Title.Length > 0 ? agent.Title : agent.Project.Length > 0 ? agent.Project : agent.Pane;
        var place = new[] { agent.Agent, agent.Project }.Where(p => p.Length > 0 && p != task).ToArray();
        var top = Ui.H(6,
            AgentParts.StatusMark(agent.Status),
            Ui.Text(agent.Status.Label(), 11.5, FontWeights.Medium, agent.Status.Ink()),
            place.Length > 0 ? Ui.Text("· " + string.Join(" · ", place), 11.5, color: tn.Sub, mono: true).Fill() : null);
        var row = Ui.H(10,
            Ui.V(4, top, Ui.Text(task, 13, FontWeights.SemiBold)).Fill(),
            when,
            Ui.Icon(Icons.ChevronRight, 11, tn.Sub));
        var tile = Ui.Tile(row, tn.Tile, agent.Status == AgentStatus.Blocked ? tn.Red : tn.Line, 0);
        tile.Padding = new Thickness(12, 10, 10, 10);
        tile.MinHeight = 54;
        return new PlainButton(tile, open).Named($"{agent.Status.Label()}, {task}").Help($"Open {task} in the agents window");
    }

    // A herdr terminal: its folder and pane in mono, and its title. This
    // computer shows no terminal, so the card takes no click.
    static UIElement TerminalCard(HerdrTerminal terminal)
    {
        var tn = Tn.Current;
        var top = Ui.H(6,
            Ui.Icon(Icons.Commands, 11, tn.Green),
            Ui.Text("Terminal", 11.5, FontWeights.Medium, tn.Green),
            Ui.Text("· " + Texts.ContextLine(terminal.Project, terminal.Pane), 11.5, color: tn.Sub, mono: true).Fill());
        var tile = Ui.Tile(Ui.V(4, top, Ui.Text(terminal.Title.Length == 0 ? "shell" : terminal.Title, 13, FontWeights.SemiBold)), tn.Tile, tn.Line, 0);
        tile.Padding = new Thickness(12, 10, 12, 10);
        tile.MinHeight = 54;
        return tile.Named($"Terminal, {(terminal.Title.Length == 0 ? "shell" : terminal.Title)}");
    }
}
