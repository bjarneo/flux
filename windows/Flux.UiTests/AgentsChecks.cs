using System.Collections.Immutable;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Media;
using Flux;
using FluxKit;
using static Harness;

// The herdr agents: the rows in the list of chats, the count in the sidebar
// and in the tray panel, the cards of the tray panel, the chat of an agent
// after a tell choice, the agents window with a thread and the changes,
// Start Agent, the agents in Control, and the settings. A blocked agent with choices, a working agent, and a done agent
// run on the paired sample computer.
public static class AgentsChecks
{
    // An approval dialog of Claude Code, with terminal colors.
    const string Dialog =
        "\u001B[38;2;215;119;87m●\u001B[0m I added the migration in \u001B[1mdb/migrate/0042_add_invoice_status.sql\u001B[0m.\n\n" +
        "\u001B[38;5;4m────────────────────────────────────────────────────────────────────────\u001B[0m\n" +
        " \u001B[1;38;5;4mBash command\u001B[0m\n\n" +
        "   bin/migrate --apply\n" +
        "   \u001B[38;5;8mApply the pending migration\u001B[0m\n\n" +
        " Do you want to proceed?\n" +
        " \u001B[38;5;4m❯ 1. Yes\u001B[0m\n" +
        "   2. Yes, and do not ask again for bin/migrate commands\n" +
        "   3. No, and tell Codex what to do differently \u001B[38;5;8m(esc)\u001B[0m\n";

    // The screen of a working agent: a message, 2 edits, a test run, and the working line.
    const string Work =
        "● I'll add a token bucket.\n\n" +
        "● Write(db/migrate/0042.sql)\n" +
        "  ⎿  Wrote 18 lines to db/migrate/0042.sql\n\n" +
        "● Update(app/models/invoice.rb)\n" +
        "  ⎿  Updated app/models/invoice.rb with 24 additions and 7 removals\n\n" +
        "● Bash(npm test -- upload)\n" +
        "  ⎿  Running 48 tests…\n" +
        "     31 passed\n\n" +
        "✻ Running tests… (2:14 · esc to interrupt)\n\n" +
        "╭──────────────────────╮\n" +
        "│ >                    │\n" +
        "╰──────────────────────╯\n" +
        "  ? for shortcuts\n";

    // The review diff that fluxd sends.
    const string Diff =
        "Changed files\n M app/models/invoice.rb\n\nWorking tree changes\n" +
        "diff --git a/app/models/invoice.rb b/app/models/invoice.rb\n" +
        "index 1111111..2222222 100644\n--- a/app/models/invoice.rb\n+++ b/app/models/invoice.rb\n" +
        "@@ -1,2 +1,3 @@\n class Invoice\n-  old_status\n+  status\n+  paid_at\n";

    public static void Run(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        var paired = h.Paired;
        var herdr = h.Core.Plugin<HerdrPlugin>();
        h.Check(herdr is not null, "the herdr plugin is in the plugin list");
        if (herdr is null)
        {
            return;
        }
        h.ApplyDevices();
        model.WatchEvents();
        var blocked = new HerdrAgent("w1:p1", "codex", AgentStatus.Blocked, "Migrate the invoices", "billing", "billing");
        var working = new HerdrAgent("w2:p1", "claude", AgentStatus.Working, "Add a token bucket", "upload", "upload");
        var done = new HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix the flaky test", "omarchy", "omarchy");
        var state = new HerdrState(true, true, [blocked, working, done], control: true,
            workspaces: [new HerdrWorkspace("w1", "billing", "~/Code/billing")], kinds: ["claude", "codex"], review: true);
        herdr.Model.States = herdr.Model.States.SetItem(paired.Id, state);
        herdr.Model.Since = herdr.Model.Since.SetItem(paired.Id, ImmutableDictionary<string, DateTimeOffset>.Empty
            .Add(working.Pane, DateTimeOffset.Now.AddSeconds(-75)));
        model.OpenChat(new ChatKey.Computer(paired.Id));
        Pump();

        // The list of chats in the sidebar.
        var chats = window.Chats;
        h.Check(Shows(chats, "Migrate the invoices") && Shows(chats, "Needs input"), "the list shows the blocked agent");
        h.Check(Shows(chats, "Add a token bucket") && Shows(chats, "Working"), "the list shows the working agent");
        h.Check(Shows(chats, "Fix the flaky test") && Shows(chats, "Done"), "the list shows the done agent");
        h.Check(Shows(chats, "1:1"), "the working agent shows its time");
        h.Check(Shows(chats, "on omarchy-xps"), "the heading of the agents names their computer");
        h.Check(Shows(chats, "2 need you"), "the context line counts the agent and the pair request");
        h.Check(Named(chats, "Needs you, 2") is not null, "the heading Needs you counts 2 items");
        h.Check(Buttons(chats).Any(b => AutomationProperties.GetName(b) == "Chats" && AutomationProperties.GetItemStatus(b) == "2 items need you"),
            "Chats tells the count to a screen reader");
        h.Check(!Shows(window.CurrentPage!, "Migrate the invoices"), "the chat of the computer shows no agent cards");
        h.Check(model.Seen.ContainsKey($"agent|{paired.Id}|w1:p1|AgentInput"), "the app model keeps the time of the blocked agent");

        // A click on an agent opens its chat with the chat top bar.
        ClickStarting(chats, "Add a token bucket");
        h.Check(model.Chat == new ChatKey.Agent(paired.Id, working.Pane), "a click on an agent opens its chat");
        h.Check(window.CurrentPage is ChatsPage { Agent: not null }, "Chats shows the chat of the agent");
        h.Check(Shows(window, "claude · upload · omarchy-xps"), "the top bar shows the agent, the project, and the computer");
        h.Check(Named(window, "Changes") is not null, "the top bar has the Changes key");
        model.OpenChat(new ChatKey.Computer(paired.Id));
        Pump();

        // The tray panel: the 2 items that need the user as cards, and the next items as rows.
        var panel = new TrayPanel(model, () => { }, () => { }, () => { });
        panel.Toggle();
        Pump();
        h.Check(Shows(panel, "2 items need you"), "the tray panel counts the agent and the pair request");
        h.Check(Shows(panel, "Migrate the invoices") && Shows(panel, "omarchy-new asks to pair"), "the tray panel shows the 2 cards");
        h.Check(Shows(panel, "Add a token bucket") && Shows(panel, "Fix the flaky test"), "the tray panel shows the next items as rows");

        // The card reads the question, and a fresh output gives the choices.
        var key = HerdrModel.PromptKey(paired.Id, blocked.Pane);
        h.Check(herdr.Model.Prompts.ContainsKey(key), "the card of the blocked agent reads its output");
        herdr.Model.Prompts = herdr.Model.Prompts.SetItem(key, new HerdrOutput(blocked.Pane, false, TermText.Lines(Dialog)));
        Pump();
        h.Check(Shows(panel, "bin/migrate --apply"), "the card shows the command of the question");
        h.Check(Shows(panel, "Yes, and do not ask again for bin/migrate commands"), "the card shows the choices");

        // A choice that rejects the action opens the chat of the agent.
        ClickStarting(panel, "3. No, and tell Codex what to do differently");
        h.Check(model.Chat == new ChatKey.Agent(paired.Id, blocked.Pane), "a tell choice opens the chat of the agent");
        panel.Close();
        herdr.Model.Outputs = herdr.Model.Outputs.SetItem(paired.Id, new HerdrOutput(blocked.Pane, false, TermText.Lines(Dialog)));
        Pump();
        h.Check(Shows(window, "codex asks") && Shows(window, "Do you want to proceed?"), "the dock of the agent chat shows the question");
        h.Check(Shows(window, "Write"), "the dock of the agent chat has Write for the text");
        // The agents window reads its own agent, so the chat of the agent closes first.
        model.OpenChat(new ChatKey.Computer(paired.Id));
        Pump();

        // The agents window with the thread of the working agent.
        AgentsWindows.Show(model, paired.Id, working.Pane);
        Pump();
        var agents = AgentsWindows.Open.GetValueOrDefault(paired.Id);
        h.Check(agents is not null, "the agents window opens");
        if (agents is not null)
        {
            CheckWindow(h, herdr, agents, paired.Id, blocked, working);
        }

        // Control lists the agents with Start Agent and Agents Window.
        model.Go(Destination.Control);
        Pump();
        h.Check(Shows(window, "Start Agent") && Shows(window, "Agents Window"), "Control shows Start Agent and Agents Window");
        h.Check(Shows(window, "3 agents · 1 needs you"), "Control counts the agents");
        h.Check(Shows(window, "Migrate the invoices") && Shows(window, "Fix the flaky test"), "Control lists the agents");
        h.Check(Shows(window, "done"), "Control shows the time of the done agent");

        // A computer with 2 herdr sessions shows them as pills.
        herdr.Model.States = herdr.Model.States.SetItem(paired.Id, state with
        {
            Sessions = ValueList.From([new HerdrSession(HerdrSession.DefaultName, true), new HerdrSession("omarchy")]),
        });
        Pump();
        h.Check(Named(window, "Session Default, 1 needs you") is not null && Named(window, "Session omarchy") is not null,
            "Control shows the session pills with the count of the agents that need the user");

        // The settings of the notifications.
        var settings = new SettingsWindow(model);
        settings.Show();
        Pump();
        Click(settings, "Features");
        h.Check(Shows(settings, "Agent needs input") && Shows(settings, "Agent finished"), "the settings show the agent notifications");
        settings.Close();

        // The tray menu has the agents of the computer.
        h.Check(TrayActions.For(model, paired).Any(a => a.Title == "Agents (1 needs input)…"), "the tray menu opens the agents");

        PlatformChecks(h);

        herdr.Model.States = ImmutableDictionary<string, HerdrState>.Empty;
        herdr.Model.Prompts = ImmutableDictionary<string, HerdrOutput>.Empty;
        herdr.Model.Outputs = ImmutableDictionary<string, HerdrOutput>.Empty;
        herdr.Model.Since = ImmutableDictionary<string, ImmutableDictionary<string, DateTimeOffset>>.Empty;
        model.OpenChat(new ChatKey.Computer(paired.Id));
        model.SetScope(null);
        model.Go(Destination.Chat);
        Pump();
    }

    static void CheckWindow(Harness h, HerdrPlugin herdr, AgentsWindow agents, string deviceId, HerdrAgent blocked, HerdrAgent working)
    {
        h.Check(Shows(agents, "3 agents"), "the agents window counts the agents");
        h.Check(Shows(agents, "Add a token bucket") && Shows(agents, "claude · w2:p1 · Working"), "the agents window shows the selected agent");
        herdr.Model.Outputs = herdr.Model.Outputs.SetItem(deviceId, new HerdrOutput(working.Pane, false, TermText.Lines(Work)));
        Pump();
        h.Check(ShowsText(agents, "I'll add a token bucket."), "the thread shows the message");
        h.Check(Shows(agents, "Changed 2 files"), "the thread shows the changes");
        h.Check(Shows(agents, "npm test -- upload"), "the thread shows the tool call");
        h.Check(Shows(agents, "Running tests") && Shows(agents, "Interrupt"), "the dock shows the step and Interrupt");

        // The changes: the diff of the folder of the agent.
        agents.View.Detail?.ShowChanges();
        Pump();
        var changes = agents.View.Detail?.Changes;
        h.Check(changes is not null, "Changes opens the changes window");
        if (changes is not null)
        {
            herdr.Model.Outputs = herdr.Model.Outputs.SetItem(deviceId, new HerdrOutput(working.Pane, false, TermText.Lines(Diff), view: "diff"));
            Pump();
            h.Check(Shows(changes, "app/models/invoice.rb") && ShowsText(changes, "+  paid_at"), "the changes show the diff");
            h.Check(ShowsText(agents, "I'll add a token bucket."), "the thread keeps the output while the changes show");
            changes.Close();
            Pump();
        }

        // The blocked agent asks in the dock.
        agents.Model.Selection = blocked.Pane;
        Pump();
        herdr.Model.Outputs = herdr.Model.Outputs.SetItem(deviceId, new HerdrOutput(blocked.Pane, false, TermText.Lines(Dialog)));
        Pump();
        h.Check(Shows(agents, "codex asks") && Shows(agents, "Do you want to proceed?"), "the dock shows the question");
        h.Check(Shows(agents, "Yes, and do not ask again for bin/migrate commands"), "the dock shows the choices");
        h.Check(Shows(agents, "Waiting for you"), "the thread tells that the agent waits");

        // Start Agent opens the dialog with the agents and the folders of the computer.
        agents.StartAgent();
        Pump();
        var start = agents.NewAgent;
        h.Check(start is not null, "Start Agent opens the dialog");
        if (start is not null)
        {
            h.Check(Shows(start, "Start an agent on omarchy-xps"), "the dialog names the computer");
            h.Check(Shows(start, "claude") && Shows(start, "codex") && Shows(start, "Claude Code"), "the dialog lists the agents of the computer");
            h.Check(Shows(start, "~/Code/billing"), "the dialog lists the folders of the workspaces");
            h.Check(Shows(start, "New tab in billing") || Shows(start, "Opens in a new workspace"), "the dialog tells where the agent opens");
            start.Close();
            Pump();
        }
        agents.Close();
        Pump();
        h.Check(!AgentsWindows.Open.ContainsKey(deviceId), "the agents window closes");
    }

    // The parts that need no screen: the lock, the terminal layout, and the recognizer.
    static void PlatformChecks(Harness h)
    {
        ReplyLock.Lock();
        h.Check(!ReplyLock.IsUnlocked, "the reply lock starts locked");
        h.Check(ReplyLock.TryStart(), "the first check of the reply lock starts");
        h.Check(!ReplyLock.TryStart(), "a second check waits for the first");
        ReplyLock.End();
        h.Check(ReplyLock.TryStart(), "a new check starts after the first ends");
        ReplyLock.End();

        var view = new TermLinesView(TermText.Lines("\u001B[42m ok \u001B[0m plain\n" + new string('x', 300)));
        view.Measure(new Size(400, double.PositiveInfinity));
        h.Check(view.DesiredSize.Height >= 3 * TermLinesView.RowHeight, "a long terminal line wraps into rows");
        h.Check(TermLinesView.Cell > 0, "the cell of the output font has a width");
        h.Check(TermColors.Color(TermColor.Indexed(1)) is SolidColorBrush, "the terminal colors map the palette");

        try
        {
            var languages = Dictation.Languages();
            Console.WriteLine($"INFO: the speech recognizer has {languages.Count} dictation languages");
        }
        catch (Exception e) when (e is TypeLoadException or System.Runtime.InteropServices.COMException or PlatformNotSupportedException)
        {
            Console.WriteLine($"SKIP: the speech recognizer is not on this runner: {e.Message}");
        }
    }

    // True when the element shows the text, also in a text block of runs,
    // such as a message of an agent or a diff.
    static bool ShowsText(DependencyObject root, string text)
    {
        if (root is System.Windows.Controls.TextBlock t &&
            new System.Windows.Documents.TextRange(t.ContentStart, t.ContentEnd).Text.Contains(text, StringComparison.Ordinal))
        {
            return true;
        }
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            if (ShowsText(VisualTreeHelper.GetChild(root, i), text))
            {
                return true;
            }
        }
        return false;
    }

    // The element with the name that a screen reader reads, or null.
    static FrameworkElement? Named(DependencyObject root, string name)
    {
        if (root is FrameworkElement fe && AutomationProperties.GetName(fe) == name)
        {
            return fe;
        }
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            if (Named(VisualTreeHelper.GetChild(root, i), name) is { } found)
            {
                return found;
            }
        }
        return null;
    }
}
