using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The last agent and folder of each computer in the dialog that starts an agent.
public static class NewAgentPrefs
{
    public static string? Run(FluxSettings settings, string deviceId) => settings.String($"herdr.run.{deviceId}");

    public static string Folder(FluxSettings settings, string deviceId) => settings.String($"herdr.folder.{deviceId}") ?? "";

    public static void Save(FluxSettings settings, string deviceId, string run, string folder)
    {
        settings.Set($"herdr.run.{deviceId}", JsonValue.Create(run));
        settings.Set($"herdr.folder.{deviceId}", JsonValue.Create(folder));
    }
}

// Starts a herdr agent on a computer. The user picks the agent from the
// agents that the computer has, then a folder. The agent opens as a new tab
// of the workspace of that folder, or in a new workspace. It can get a first
// task, which Flux sends when the agent is ready. This computer does not
// show terminals, so the dialog starts agents only. The new agent is
// selected in the agents window when the computer reports it. Escape closes
// the dialog. NewAgentSheet.swift of the Mac app has the same parts.
public sealed class NewAgentDialog : Window
{
    public NewAgentDialog(AgentsWindowModel model)
    {
        Title = $"Start an agent on {model.Name}";
        Width = 540;
        Height = 620;
        MinWidth = 460;
        MinHeight = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        FontFamily = Faces.Body;
        Background = Tn.Current.Bg;
        var view = new NewAgentView(model, this);
        Content = view;
        Tn.Changed += Retheme;
        Closed += (_, _) => Tn.Changed -= Retheme;
        InputBindings.Add(new KeyBinding(new Relay(() =>
        {
            if (!view.Busy)
            {
                Close();
            }
        }), Key.Escape, ModifierKeys.None));
    }

    void Retheme() => Background = Tn.Current.Bg;

    sealed class NewAgentView : View
    {
        readonly AgentsWindowModel model;
        readonly NewAgentDialog dialog;
        readonly TextBox query = new()
        {
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            FontFamily = Faces.Mono,
            FontSize = 13,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        readonly TextBox task;
        readonly Border queryFrame;
        readonly Border taskFrame;
        readonly TextBlock queryHint = Ui.Text("Search, or type a path such as ~/Code/app", 13, mono: true);
        readonly TextBlock taskHint = Ui.Text("Optional. Sent when the agent is ready.", 13);
        // The form keeps its scroll position while the search changes the folders.
        readonly ScrollViewer form = Ui.Scroll(new Border());
        string? run;
        string folder;
        bool newWorkspace;
        string? lockError;
        // Only a create from this dialog counts. Its number is higher than
        // the last action at the click.
        int after = int.MaxValue;

        public NewAgentView(AgentsWindowModel model, NewAgentDialog dialog)
        {
            this.model = model;
            this.dialog = dialog;
            var settings = model.App.Core.Settings;
            var saved = NewPane.NormalFolder(NewAgentPrefs.Folder(settings, model.DeviceId));
            run = NewAgentPrefs.Run(settings, model.DeviceId);
            folder = saved.Length == 0 ? "~" : saved;
            Watch(model.App);
            Watch(model.Plugin.Model);
            task = AgentParts.ReplyField(() => Start());
            task.TextChanged += (_, _) => Invalidate();
            query.TextChanged += (_, _) => Invalidate();
            query.PreviewKeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter && NewPane.LooksLikePath(query.Text))
                {
                    e.Handled = true;
                    Select(query.Text);
                }
            };
            System.Windows.Automation.AutomationProperties.SetName(query, "Search the folders, or type a path");
            System.Windows.Automation.AutomationProperties.SetName(task, "Task");
            queryFrame = new Border
            {
                Child = Ui.H(8, Ui.Icon(Icons.Search, 13, Tn.Current.Sub), AgentParts.WithHint(query, queryHint).Fill(), FieldKeys.Clear(query)),
                CornerRadius = new CornerRadius(Metrics.TileCorner),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12, 0, 8, 0),
                Height = 36,
            };
            taskFrame = new Border
            {
                Child = Ui.H(4, AgentParts.WithHint(task, taskHint).Fill(), FieldKeys.Clear(task).Margin(0, 0, 8, 0)),
                CornerRadius = new CornerRadius(Metrics.TileCorner),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(6, 0, 0, 0),
            };
        }

        HerdrPlugin Plugin => model.Plugin;

        // The create of this dialog, or null.
        HerdrAction? Action => Plugin.Model.Actions.GetValueOrDefault(model.DeviceId) is { Action: "create" } a && a.Seq > after ? a : null;

        // True while the computer starts the agent.
        public bool Busy => Action?.Sending == true;

        // The folder of the new agent. A typed path is the folder at once.
        // Enter or a click on its row keeps it after the search.
        string Target => NewPane.LooksLikePath(query.Text) ? NewPane.NormalFolder(query.Text) : folder;

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            var name = model.Name;
            var herdr = model.Shown;
            var session = (model.Herdr?.Sessions.Count ?? 0) > 1 ? Plugin.Model.Session(model.DeviceId) : null;
            var action = Action;
            // The new agent is selected when the computer reports its pane.
            if (action is { Sending: false, Error: null, Pane: { } pane })
            {
                Plugin.ClearAction(model.DeviceId, action.Seq);
                model.Selection = pane;
                Dispatcher.BeginInvoke(DispatcherPriority.Background, dialog.Close);
            }
            run = NewPane.PickRun(run, (IReadOnlyList<string>?)herdr?.Kinds ?? [], false);
            var busy = action?.Sending == true;
            var title = Ui.Text(session is null ? $"Start an agent on {name}" : $"Start an agent in {session.Label} on {name}", 15, FontWeights.SemiBold).Fill();
            System.Windows.Automation.AutomationProperties.SetHeadingLevel(title, System.Windows.Automation.AutomationHeadingLevel.Level1);
            var head = Ui.H(8, title, new FluxButton("Cancel", ButtonKind.Outlined, dialog.Close, enabled: !busy).Named("Cancel").Help("Close the dialog (Esc)"))
                .Margin(16, 12, 16, 12);
            var layout = new DockPanel();
            var top = Ui.V(0, head, new Border { Height = 1, Background = tn.Line });
            DockPanel.SetDock(top, Dock.Top);
            layout.Children.Add(top);
            if (model.Device?.Online != true)
            {
                layout.Children.Add(Parts.Unavailable(Icons.Wifi, $"{name} is offline", $"Agents start when {name} is on the same network."));
            }
            else if (herdr is { Running: true, Control: true, Kinds.Count: > 0 })
            {
                Form(layout, herdr, action, busy);
            }
            else if (herdr?.Running != true)
            {
                layout.Children.Add(Parts.Unavailable(AgentGlyphs.Agent, "herdr is not running", $"Start herdr on {name}. Then start agents from here."));
            }
            else if (!herdr.Control)
            {
                layout.Children.Add(Parts.Unavailable(AgentGlyphs.Agent, "Control is off",
                    $"To start agents from this computer, turn on Agent control in Flux on {name}, on the Access card."));
            }
            else
            {
                layout.Children.Add(Parts.Unavailable(AgentGlyphs.Agent, $"No coding agent on {name}",
                    $"Install a coding agent that herdr supports, such as Claude Code or Codex, on {name}. It shows here within a minute."));
            }
            return layout;
        }

        void Form(DockPanel layout, HerdrState herdr, HerdrAction? action, bool busy)
        {
            var tn = Tn.Current;
            var target = Target;
            var match = NewPane.WorkspaceFor(herdr, target);
            var workspace = match is not null && !newWorkspace ? match.Id : "";
            queryFrame.Background = tn.Tile;
            queryFrame.BorderBrush = tn.LineHi;
            queryFrame.IsEnabled = !busy;
            query.Foreground = tn.Text;
            queryHint.Foreground = tn.Dim;
            taskFrame.Background = tn.Tile;
            taskFrame.BorderBrush = tn.LineHi;
            taskFrame.IsEnabled = !busy;
            task.Foreground = tn.Text;
            taskHint.Foreground = tn.Dim;
            var tooLong = Encoding.UTF8.GetByteCount(task.Text) > HerdrWire.MaxPrompt;
            var tiles = herdr.Kinds.Select(k => (UIElement)RunTile(k, herdr.Agents.Count(a => a.Agent == k), k == run, busy)).ToArray();
            var items = new List<UIElement?>
            {
                Label("Run"),
                Parts.GridRows(tiles, 2),
                Label("Task").Margin(4, 8, 0, 0),
                taskFrame,
                tooLong ? Ui.Text("The task is too long. The limit is 16 KB.", 11, color: tn.Red) : null,
                Label("Folder").Margin(4, 8, 0, 0),
                Ui.H(8, queryFrame.Fill(), new FluxButton("Browse…", ButtonKind.Outlined, () => Browse(target), enabled: !busy).Named("Browse")
                    .Help($"Pick a folder from the folders of {model.Name}")),
            };
            items.AddRange(FolderList(NewPane.FolderChoices(herdr), target, busy));
            var bottom = StartBar(match, target, busy, tooLong, lockError ?? action?.Error, workspace);
            DockPanel.SetDock(bottom, Dock.Bottom);
            layout.Children.Add(bottom);
            form.Content = Ui.V(10, items).Margin(16);
            Ui.Detach(form);
            layout.Children.Add(form);
        }

        static FrameworkElement Label(string text)
        {
            var t = Ui.Text(text.ToUpperInvariant(), 11, FontWeights.SemiBold, Tn.Current.Sub).Margin(4, 0, 0, 0);
            System.Windows.Automation.AutomationProperties.SetHeadingLevel(t, System.Windows.Automation.AutomationHeadingLevel.Level2);
            return t;
        }

        // 1 agent kind with its product name. running counts the agents of the kind that run now.
        UIElement RunTile(string kind, int running, bool selected, bool busy)
        {
            var tn = Tn.Current;
            var sub = string.Join(" · ", new[] { NewPane.AgentProduct(kind), running > 0 ? $"{running} running" : null }.OfType<string>());
            var tile = new Border
            {
                Child = Ui.H(10,
                    Ui.Icon(AgentGlyphs.Agent, 16, tn.Magenta, 22),
                    Ui.V(2, Ui.Text(kind, 13, FontWeights.SemiBold, mono: true), Ui.Text(sub.Length == 0 ? " " : sub, 11, color: tn.Sub)).Fill()),
                Background = selected ? tn.AccentTile : tn.Tile,
                BorderBrush = selected ? tn.Magenta : tn.LineHi,
                BorderThickness = new Thickness(selected ? 2 : 1),
                CornerRadius = new CornerRadius(Metrics.TileCorner),
                Padding = new Thickness(12, 6, 12, 6),
                MinHeight = 52,
            };
            var b = new PlainButton(tile, () =>
            {
                run = kind;
                Invalidate();
            }) { IsEnabled = !busy };
            System.Windows.Automation.AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
            return b.Named(sub.Length == 0 ? kind : $"{kind}, {sub}");
        }

        IEnumerable<UIElement> FolderList(IReadOnlyList<FolderChoice> folders, string selected, bool busy)
        {
            var typedPath = NewPane.NormalFolder(query.Text);
            var typed = NewPane.LooksLikePath(query.Text);
            if (typed && !folders.Any(f => f.Path == typedPath))
            {
                yield return FolderRow(new FolderChoice(typedPath, NewPane.FolderName(typedPath), null, 0), true, busy, () => Select(typedPath), typed: true);
            }
            if (query.Text.Length == 0 && !folders.Any(f => f.Path == selected))
            {
                yield return FolderRow(new FolderChoice(selected, NewPane.FolderName(selected), null, 0), true, busy, () => { });
            }
            var shown = NewPane.FilterFolders(folders, typed ? "" : query.Text);
            foreach (var f in shown)
            {
                yield return FolderRow(f, f.Path == selected, busy, () => Select(f.Path));
            }
            if (shown.Count == 0 && !typed)
            {
                yield return Ui.Text($"No folder has \"{query.Text}\". Type a path that starts with ~/ or /.", 11, color: Tn.Current.Sub, wrap: true);
            }
        }

        // A folder: its name, its path, and the agents in its workspace.
        // typed marks a new path from the search field.
        static UIElement FolderRow(FolderChoice folder, bool selected, bool busy, Action pick, bool typed = false)
        {
            var tn = Tn.Current;
            var row = Ui.H(12,
                Ui.Icon(folder.Path == "~" ? AgentGlyphs.Home : Icons.Folder, 14, selected || typed ? tn.Accent : tn.Sub, 20),
                Ui.V(2, Ui.Text(folder.Name, 13, FontWeights.SemiBold), Ui.Text(folder.Path, 11, color: tn.Sub, mono: true)).Fill(),
                typed ? Ui.Text("typed", 11, color: tn.Sub) : null,
                folder.Agents > 0 ? Ui.Text(folder.Agents == 1 ? "1 agent" : $"{folder.Agents} agents", 11, color: tn.Sub) : null,
                selected ? Ui.Icon(Icons.Check, 13, tn.Accent).Named("Selected") : null);
            var tile = new Border
            {
                Child = row,
                Background = selected ? tn.AccentTile : tn.Tile,
                BorderBrush = selected ? tn.Accent : tn.LineHi,
                BorderThickness = new Thickness(selected ? 2 : 1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 4, 12, 4),
                MinHeight = 44,
            };
            return new PlainButton(tile, pick) { IsEnabled = !busy }.Named($"{folder.Name}, {folder.Path}");
        }

        void Select(string path)
        {
            folder = NewPane.NormalFolder(path);
            query.Clear();
            newWorkspace = false;
            Invalidate();
        }

        void Browse(string target)
        {
            var browser = new FolderBrowserDialog(model, target, Select) { Owner = dialog };
            browser.Show();
        }

        UIElement StartBar(HerdrWorkspace? match, string target, bool busy, bool tooLong, string? problem, string workspace)
        {
            var tn = Tn.Current;
            var canStart = run is not null && !busy && !tooLong;
            var label = run is null ? "Select an agent" : busy ? $"Starting {run}. This can take 30 seconds." : $"Start {run} in {NewPane.FolderName(target)}";
            var items = new List<UIElement?>();
            if (match is not null)
            {
                items.Add(Ui.H(6,
                    Choice($"New tab in {match.Label}", !newWorkspace, busy, () => newWorkspace = false),
                    Choice("New workspace", newWorkspace, busy, () => newWorkspace = true)));
            }
            else
            {
                items.Add(Ui.Text("Opens in a new workspace, because no workspace has this folder.", 11, color: tn.Sub, wrap: true));
            }
            if (problem is not null)
            {
                items.Add(Ui.Text(problem, 11, color: tn.Red, wrap: true));
            }
            var start = new FluxButton(label, ButtonKind.Filled, () => Start(target, workspace), enabled: canStart) { IsDefault = canStart }.Named(label);
            items.Add(Ui.H(10, Ui.Spacer(), busy ? Parts.Spinner(14) : null, start));
            var bar = Ui.V(8, items).Margin(16);
            return Ui.V(0, new Border { Height = 1, Background = tn.Line }, bar);
        }

        UIElement Choice(string title, bool selected, bool busy, Action pick)
        {
            var tn = Tn.Current;
            var chip = new Border
            {
                Child = Ui.Text(title, 13, FontWeights.SemiBold, selected ? tn.Text : tn.Sub),
                Background = selected ? tn.AccentTile : tn.Tile,
                BorderBrush = selected ? tn.Accent : tn.Line,
                BorderThickness = new Thickness(selected ? 2 : 1),
                CornerRadius = new CornerRadius(Metrics.SmallCorner),
                Padding = new Thickness(12, 5, 12, 5),
            };
            var b = new PlainButton(chip, () =>
            {
                pick();
                Invalidate();
            }) { IsEnabled = !busy };
            System.Windows.Automation.AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
            return b.Named(title);
        }

        void Start() => Start(Target, model.Shown is { } h && NewPane.WorkspaceFor(h, Target) is { } m && !newWorkspace ? m.Id : "");

        void Start(string target, string workspace)
        {
            if (run is not { } kind || Encoding.UTF8.GetByteCount(task.Text) > HerdrWire.MaxPrompt || Busy)
            {
                return;
            }
            lockError = null;
            var last = Plugin.Model.Actions.GetValueOrDefault(model.DeviceId)?.Seq ?? 0;
            var text = task.Text;
            ReplyLock.Run($"start an agent on {model.Name}", dialog, () =>
            {
                after = last;
                NewAgentPrefs.Save(model.App.Core.Settings, model.DeviceId, kind, target);
                Plugin.Create(model.DeviceId, "agent", kind, target, workspace, text, Plugin.Model.CreateSession(model.DeviceId));
                Invalidate();
            }, message =>
            {
                lockError = message;
                Invalidate();
            });
        }
    }
}

// The state of the first task of a new agent, until it went. A task that did
// not go waits in the reply field of the agent. FirstTaskNote of the Mac app
// has the same texts.
public sealed class FirstTaskNote(AgentsWindowModel model, string pane, Action<string> fill)
{
    FirstTaskPhase? shown;
    DispatcherTimer? clear;

    public UIElement? Build(HerdrAgent agent)
    {
        var tn = Tn.Current;
        if (!model.Plugin.Model.FirstTasks.TryGetValue(model.DeviceId, out var task) || task.Pane != pane)
        {
            return null;
        }
        var phase = task.Phase;
        if (phase != shown)
        {
            shown = phase;
            Changed(task);
        }
        var (mark, text) = phase.State switch
        {
            FirstTaskState.Starting or FirstTaskState.Waiting => ((UIElement)Parts.Spinner(12), $"Flux sends your task when {agent.Agent} is ready."),
            FirstTaskState.Answering => (Ui.Icon(AgentGlyphs.Question, 12, tn.Orange), $"Answer {agent.Agent} first. Then Flux sends your task."),
            FirstTaskState.Sending => (Parts.Spinner(12), "Sending your task…"),
            FirstTaskState.Sent => (Ui.Icon(AgentGlyphs.Completed, 12, tn.Green), $"{agent.Agent} got your task."),
            _ => (Ui.Icon(Icons.Warning, 12, tn.Red), $"Your task did not go: {phase.Error} It is in the reply field."),
        };
        return Ui.H(8, mark, Ui.Text(text, 12, color: tn.Sub, wrap: true).Fill()).Margin(16, 6, 16, 6);
    }

    // A sent task goes after 4 seconds. A failed task goes to the reply
    // field, and its note goes after 8 seconds.
    void Changed(FirstTask task)
    {
        clear?.Stop();
        clear = null;
        TimeSpan? after = task.Phase.State switch
        {
            FirstTaskState.Sent => TimeSpan.FromSeconds(4),
            FirstTaskState.Failed => TimeSpan.FromSeconds(8),
            _ => null,
        };
        if (task.Phase.State == FirstTaskState.Failed)
        {
            fill(task.Text);
        }
        if (after is not { } delay)
        {
            return;
        }
        clear = new DispatcherTimer { Interval = delay };
        clear.Tick += (_, _) =>
        {
            clear?.Stop();
            clear = null;
            model.Plugin.ClearFirstTask(model.DeviceId);
        };
        clear.Start();
    }
}

// The Get files session of each computer. fluxd has 1 Get files session for
// each computer, so the Get files window and the folder picker of a new
// agent share it. A lease keeps the session open, and the last release
// closes it. BrowseWindows.lease of the Mac app has the same job.
public static class BrowseLease
{
    static readonly Dictionary<string, int> Counts = [];

    // The browser of the computer, or null without Get files.
    public static BrowseModel? Take(AppModel app, string deviceId)
    {
        if (app.Core.Plugin<BrowsePlugin>()?.Browser(deviceId) is not { } browser)
        {
            return null;
        }
        Counts[deviceId] = Counts.GetValueOrDefault(deviceId) + 1;
        return browser;
    }

    public static void Release(AppModel app, string deviceId)
    {
        var n = Counts.GetValueOrDefault(deviceId) - 1;
        if (n > 0)
        {
            Counts[deviceId] = n;
            return;
        }
        Counts.Remove(deviceId);
        app.Core.Plugin<BrowsePlugin>()?.Close(deviceId);
    }
}

// Picks a folder on a computer for a new agent. It browses the folders of
// Get files: the home folder and the usual folders, without hidden ones. It
// opens at chosen, the chosen folder in the form of herdr. pick gets the
// folder in the same form, such as ~/Code/app. Escape closes it.
// FolderBrowserSheet.swift of the Mac app has the same parts.
public sealed class FolderBrowserDialog : Window
{
    public FolderBrowserDialog(AgentsWindowModel model, string chosen, Action<string> pick)
    {
        Title = $"Choose a folder on {model.Name}";
        Width = 520;
        Height = 560;
        MinWidth = 420;
        MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        FontFamily = Faces.Body;
        Background = Tn.Current.Bg;
        var browser = BrowseLease.Take(model.App, model.DeviceId);
        Content = new FolderView(model, browser, chosen, path =>
        {
            pick(path);
            Close();
        }, Close);
        Closed += (_, _) =>
        {
            if (browser is not null)
            {
                BrowseLease.Release(model.App, model.DeviceId);
            }
        };
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
    }

    sealed class FolderView : View
    {
        readonly AgentsWindowModel model;
        readonly BrowseModel? browser;
        readonly string chosen;
        readonly Action<string> pick;
        readonly Action close;
        bool openedChosen;

        public FolderView(AgentsWindowModel model, BrowseModel? browser, string chosen, Action<string> pick, Action close)
        {
            this.model = model;
            this.browser = browser;
            this.chosen = chosen;
            this.pick = pick;
            this.close = close;
            Watch(browser);
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            var name = model.Name;
            var title = Ui.Text($"Choose a folder on {name}", 15, FontWeights.SemiBold).Fill();
            System.Windows.Automation.AutomationProperties.SetHeadingLevel(title, System.Windows.Automation.AutomationHeadingLevel.Level1);
            var head = Ui.V(0, Ui.H(8, title, new FluxButton("Cancel", ButtonKind.Outlined, close).Named("Cancel").Help("Close (Esc)")).Margin(16, 12, 16, 12),
                new Border { Height = 1, Background = tn.Line });
            var layout = new DockPanel();
            DockPanel.SetDock(head, Dock.Top);
            layout.Children.Add(head);
            if (browser is not { } b)
            {
                layout.Children.Add(Parts.Unavailable(Icons.Folder, $"Cannot browse {name}", $"Get files is not available for {name}."));
                return layout;
            }
            OpenChosen(b);
            var home = b.Roots.FirstOrDefault()?.Path ?? "";
            var folder = b.Path.Length == 0 ? "" : NewPane.HomeRelative(b.Path, home);
            var crumbs = Crumbs(b);
            DockPanel.SetDock(crumbs, Dock.Top);
            layout.Children.Add(crumbs);
            var use = new FluxButton("Use This Folder", ButtonKind.Filled, () => pick(folder),
                enabled: folder.Length > 0 && !b.Loading && b.Error is null) { IsDefault = true }.Named("Use This Folder");
            var bottom = Ui.V(0, new Border { Height = 1, Background = tn.Line },
                Ui.H(10, Ui.Text(folder.Length == 0 ? " " : folder, 12, color: tn.Sub, mono: true).Fill(), use).Margin(16));
            DockPanel.SetDock(bottom, Dock.Bottom);
            layout.Children.Add(bottom);
            if (b.Error is { } error)
            {
                layout.Children.Add(Ui.V(12, Parts.Unavailable(Icons.Warning, "Cannot list the folder", error),
                    new FluxButton("Try Again", ButtonKind.Outlined, b.Retry).Named("Try Again").Align(HorizontalAlignment.Center)).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            }
            else if (b.Loading && b.Entries.Count == 0)
            {
                layout.Children.Add(Ui.H(10, Parts.Spinner(), Ui.Text(b.Path.Length == 0 ? $"Connecting to {name}…" : "Loading…", 13, color: tn.Sub))
                    .Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            }
            else
            {
                layout.Children.Add(Folders(b));
            }
            return layout;
        }

        // Opens the chosen folder when the session knows its shared folders.
        // A folder outside them leaves the picker where Get files is.
        void OpenChosen(BrowseModel b)
        {
            if (openedChosen || b.Roots.FirstOrDefault()?.Path is not { } home)
            {
                return;
            }
            openedChosen = true;
            if (NewPane.AbsoluteFolder(chosen, home) is { } path && BrowsePath.Root(path, b.Roots) is not null && path != b.Path)
            {
                Dispatcher.BeginInvoke(DispatcherPriority.Background, () => b.Open(path));
            }
        }

        // Up, then the folders from the root down to the current one.
        UIElement Crumbs(BrowseModel b)
        {
            var tn = Tn.Current;
            var items = new List<UIElement?>
            {
                new FluxButton("", ButtonKind.Text, b.GoUp, AgentGlyphs.ChevronUp, enabled: b.CanGoUp).Named("Up").Help("Open the folder above"),
            };
            var crumbs = b.Crumbs;
            for (var i = 0; i < crumbs.Count; i++)
            {
                if (i > 0)
                {
                    items.Add(Ui.Icon(Icons.ChevronRight, 9, tn.Dim));
                }
                var crumb = crumbs[i];
                var last = i == crumbs.Count - 1;
                items.Add(new PlainButton(Ui.Text(crumb.Name, 12, color: last ? tn.Text : tn.Sub).Margin(4, 2, 4, 2), () => b.Open(crumb.Path)).Named(crumb.Name));
            }
            var row = new ScrollViewer
            {
                Content = Ui.H(2, items),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Focusable = false,
            };
            UIElement? roots = null;
            if (b.Roots.Count > 1)
            {
                FluxButton? button = null;
                button = new FluxButton("", ButtonKind.Text, () =>
                {
                    var menu = new ContextMenu { PlacementTarget = button };
                    foreach (var r in b.Roots)
                    {
                        var item = new MenuItem { Header = r.Name };
                        item.Click += (_, _) => b.Open(r.Path);
                        menu.Items.Add(item);
                    }
                    menu.IsOpen = true;
                }, AgentGlyphs.Drive).Named("Open another shared folder").Help("Open another shared folder");
                roots = button;
            }
            return Ui.H(4, row.Fill(), roots).Margin(12, 8, 12, 8);
        }

        UIElement Folders(BrowseModel b)
        {
            var tn = Tn.Current;
            var folders = b.Entries.Where(e => e.Dir).ToArray();
            if (folders.Length == 0)
            {
                return Ui.Text("No folders in here. Use this folder, or go up.", 12, color: tn.Sub, align: TextAlignment.Center)
                    .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            }
            var rows = folders.Select(e =>
            {
                var row = Ui.H(10, Ui.Icon(Icons.Folder, 14, tn.Accent), Ui.Text(e.Name, 13).Fill(), Ui.Icon(Icons.ChevronRight, 10, tn.Dim));
                var tile = new Border { Child = row, Padding = new Thickness(10, 6, 10, 6), MinHeight = Metrics.RowHeight, Background = System.Windows.Media.Brushes.Transparent };
                return (UIElement)new PlainButton(tile, () => b.Open(e.Path)).Named(e.Name);
            });
            return Ui.Scroll(Ui.V(0, rows).Margin(8, 4, 8, 4));
        }
    }
}
