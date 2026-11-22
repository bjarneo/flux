using System.Collections.Immutable;
using System.Diagnostics;
using System.Text;

namespace FluxKit;

// flux.herdr in both directions. fluxd sends the coding agents that herdr
// runs on the computer, and this device asks for the recent output of an
// agent. When the computer allows it, this device also sends keys and
// prompts to an agent, starts agents, and closes them. When the computer
// allows terminals, it also opens terminals and types in them.
// docs/herdr.md describes the feature and the wire format. HerdrPlugin.swift
// of the Mac app has the same rules.
//
// The UI calls the public methods on the UI thread. The plugin changes its
// model only on the UI thread: a packet from the network goes through
// core.Host.Post. A lock guards the state of the plugin as well, so that a
// test without a UI thread can call it from any thread.
public sealed class HerdrPlugin : IFluxPlugin
{
    public const string NotificationCategory = "herdr";
    internal const string DeviceKey = "device";
    internal const string PaneKey = "pane";
    internal const string DialogKey = "dialog";
    internal const string ChoiceAction = "choice:";
    internal const string ReplyAction = "reply";
    internal const string InputAlertsKey = "herdr.inputAlerts";
    internal const string DoneAlertsKey = "herdr.doneAlerts";
    internal const string DictationLanguageKey = "herdr.dictationLanguage";
    internal const string SessionsKey = "herdr.sessions";

    // How long a finished agent must stay ready before this device posts it.
    // The status can change between tool calls.
    public static readonly TimeSpan FinishHold = TimeSpan.FromSeconds(2);

    // How long a read waits for the output. fluxd can take 10 seconds to
    // collect the history of an agent.
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(15);

    // How long a new agent or terminal waits. fluxd waits up to 45 seconds
    // for herdr to start an agent.
    public static readonly TimeSpan CreateTimeout = TimeSpan.FromSeconds(60);

    // How long a reply waits for the answer of the computer.
    public static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(10);

    // How long a close waits for the answer of the computer.
    public static readonly TimeSpan CloseTimeout = TimeSpan.FromSeconds(10);

    // How long this device waits after a reply before it reads the output
    // again. The agent needs a moment to draw.
    public static readonly TimeSpan RereadDelay = TimeSpan.FromMilliseconds(700);

    // How long a reply in the place of a choice waits for the agent to leave its dialog, see Tell.
    public static readonly TimeSpan TellWait = TimeSpan.FromSeconds(4);

    // How often a reply in the place of a choice checks the status of the agent.
    public static readonly TimeSpan TellStep = TimeSpan.FromMilliseconds(250);

    // How often the agent screen reads the output again while the agent works, see Watch.
    public static readonly TimeSpan WorkingRefresh = TimeSpan.FromSeconds(5);

    public IReadOnlyList<string> Incoming { get; } = [PacketType.Herdr];
    public IReadOnlyList<string> Outgoing { get; } = [PacketType.Herdr];
    public HerdrModel Model { get; } = new();

    readonly object gate = new();
    FluxCore? core;
    readonly Dictionary<string, HerdrTracker> trackers = [];

    // The status times of the agents of each computer, by device ID.
    readonly Dictionary<string, AgentClock> clocks = [];

    // The finished notifications that wait for FinishHold, by device ID and pane.
    readonly Dictionary<string, Action> pending = [];

    // Counts the reads of each computer and all replies, so that a late
    // timeout does not replace a newer answer. A read of 1 computer does not
    // cancel the read timeout of another computer.
    readonly Dictionary<string, int> reads = [];
    readonly Dictionary<string, string> reviews = [];
    readonly Dictionary<string, HerdrViewRead> viewReads = [];
    int replies;

    // Counts the creates and the closes, so that a late timeout does not
    // replace a newer one.
    int actions;

    // Counts the output parses of each computer, so that an older parse that
    // ends late does not replace a newer output.
    readonly Dictionary<string, int> parses = [];

    // The number of the last read and of the last parse of each prompt of
    // the Inbox, by HerdrModel.PromptKey, as reads and parses do for the
    // agent screen. Each number comes from promptSeq and is not used again,
    // also after KeepPrompts drops a prompt. A late timeout or parse of a
    // dropped prompt then does not match a new read of the same agent.
    readonly Dictionary<string, int> promptReads = [];

    // The dialog reads that wait for an answer, by HerdrModel.PromptKey. A
    // pane has at most 1, because fluxd answers only the newest read of a
    // pane. See PeekDialog.
    readonly Dictionary<string, DialogWait> dialogWaits = [];

    // The last dialog that a read found for each blocked pane, by HerdrModel.PromptKey.
    readonly Dictionary<string, AgentDialog> dialogs = [];

    // The categories of notifications that are registered, by dialog ID.
    readonly HashSet<string> dialogCategories = [];
    int dialogSeq;

    sealed class DialogWait
    {
        public List<Action<AgentDialog?>> Callbacks { get; } = [];

        // The request number of the read, or null for a read of the agent screen.
        public int? Request { get; set; }
    }

    // The time of this device. Tests set their own.
    internal Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.Now;

    // Asks the person at this computer to unlock before an answer from a
    // notification goes out. The app sets it to Windows Hello. It calls the
    // first action when the unlock is valid, and the second action with a
    // message when the check fails. A cancel calls neither. Without it, an
    // answer from a notification sends nothing and opens the thread.
    public Action<string, Action, Action<string>>? Unlock { get; set; }
    internal Dictionary<string, int> PromptParses { get; } = [];
    int promptSeq;

    // The agent that the agent screen of each computer shows, by device ID, see Watch.
    readonly Dictionary<string, Watcher> watches = [];

    sealed class Watcher(string pane, bool review)
    {
        public string Pane { get; } = pane;
        public bool Review { get; } = review;
        public AgentStatus? Status { get; set; }
        public Action? CancelPoll { get; set; }
    }

    static readonly Stopwatch Uptime = Stopwatch.StartNew();

    // The time in seconds for the first task. Tests set their own.
    internal Func<double> Clock { get; set; } = () => Uptime.Elapsed.TotalSeconds;

    // Runs an action on the UI thread after a delay and returns a function
    // that cancels it. Tests set a manual clock.
    internal Func<TimeSpan, Action, Action> After { get; set; }

    // True when the computer has a link now. Tests set their own.
    internal Func<string, bool> IsOnline { get; set; }

    // Sends a packet to a computer and returns false when the computer is
    // not reachable. Tests set their own to see the packets.
    internal Func<Packet, string, bool> Send { get; set; }

    public HerdrPlugin()
    {
        After = DefaultAfter;
        IsOnline = id => core?.WithDevice(id, d => d.Online) == true;
        Send = (p, id) => core?.Send(p, id) == true;
    }

    public void Attach(FluxCore core)
    {
        this.core = core;
        Model.Load(core.Settings);
        core.Host.Notifier.Register(NotificationCategory, [], OnNotificationAction);
    }

    // The next agent list sets the start values, so a reconnect posts nothing.
    public void OnConnected(Device device)
    {
        var id = device.Id;
        Post(() => Locked(() =>
        {
            Tracker(id).Restart();
            ClockOf(id).Restart();
            RefreshWatch(id);
        }));
    }

    // The poll of the agent screen stops while the computer is away.
    public void OnDisconnected(Device device)
    {
        var id = device.Id;
        Post(() => Locked(() =>
        {
            if (watches.TryGetValue(id, out var w))
            {
                w.CancelPoll?.Invoke();
                w.CancelPoll = null;
            }
        }));
    }

    // The core lock is held. The UI thread keeps the order of the packets.
    public void Handle(Packet packet, Device device)
    {
        var id = device.Id;
        var name = device.Name;
        Post(() => Receive(packet, id, name));
    }

    void Post(Action action)
    {
        if (core is { } c)
        {
            c.Host.Post(action);
        }
        else
        {
            action();
        }
    }

    void Locked(Action action)
    {
        lock (gate)
        {
            action();
        }
    }

    Action DefaultAfter(TimeSpan delay, Action action)
    {
        var cancel = new CancellationTokenSource();
        _ = Task.Delay(delay, cancel.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled)
            {
                Post(() =>
                {
                    if (!cancel.IsCancellationRequested)
                    {
                        action();
                    }
                });
            }
        }, TaskScheduler.Default);
        return cancel.Cancel;
    }

    // Runs action under the lock after delay, and returns a function that cancels it.
    Action Schedule(TimeSpan delay, Action action) => After(delay, () => Locked(action));

    HerdrTracker Tracker(string id)
    {
        if (!trackers.TryGetValue(id, out var t))
        {
            trackers[id] = t = new HerdrTracker();
        }
        return t;
    }

    AgentClock ClockOf(string id)
    {
        if (!clocks.TryGetValue(id, out var c))
        {
            clocks[id] = c = new AgentClock();
        }
        return c;
    }

    // Packets

    internal void Receive(Packet p, string deviceId, string computer)
    {
        lock (gate)
        {
            switch (p.String("kind"))
            {
                case "state":
                    ReceiveState(p, deviceId, computer);
                    break;
                case "output":
                    ReceiveOutput(p, deviceId);
                    break;
                case "sent":
                    ReceiveSent(p, deviceId);
                    break;
                case "created":
                case "closed":
                    ReceiveDone(p, deviceId);
                    break;
                default:
                    FluxLog.Debug("herdr", $"ignored kind {p.String("kind") ?? ""}");
                    break;
            }
        }
    }

    void ReceiveState(Packet p, string deviceId, string computer)
    {
        if (HerdrWire.State(p.Body) is not { } state)
        {
            return;
        }
        Model.States = Model.States.SetItem(deviceId, state);
        // A state with the same times leaves the model as it is, so that the views do not update.
        var since = ClockOf(deviceId).Update(state.Agents, DateTimeOffset.Now);
        if (!Model.Since.TryGetValue(deviceId, out var old) || old.Count != since.Count ||
            since.Any(e => !old.TryGetValue(e.Key, out var at) || at != e.Value))
        {
            Model.Since = Model.Since.SetItem(deviceId, since.ToImmutableDictionary());
        }
        var alerts = Tracker(deviceId).Update(state.Agents);
        Alert(alerts, deviceId, computer);
        AdvanceFirstTask(deviceId);
        // A new status of the agent on the agent screen reads at once.
        if (watches.TryGetValue(deviceId, out var w) && state.Agent(w.Pane)?.Status != w.Status)
        {
            RefreshWatch(deviceId);
        }
    }

    void ReceiveOutput(Packet p, string deviceId)
    {
        // Only the pane on screen and the prompts of the Inbox keep their
        // output. The check reads the pane before the parse, and the parse
        // of up to 1 MiB of text runs off the UI thread.
        if (p.String("pane") is not { Length: > 0 } pane)
        {
            return;
        }
        var key = HerdrModel.PromptKey(deviceId, pane);
        int? window = null;
        if (Model.Outputs.TryGetValue(deviceId, out var shown) && shown.Pane == pane &&
            AcceptsView(deviceId, pane, p.Int("request"), p.String("view") ?? "ansi", p.String("path") ?? ""))
        {
            var n = parses.GetValueOrDefault(deviceId) + 1;
            parses[deviceId] = n;
            window = n;
        }
        int? prompt = null;
        if (Model.Prompts.ContainsKey(key) && p.String("view") != "diff" && p.Int("request") is null)
        {
            promptSeq++;
            PromptParses[key] = promptSeq;
            prompt = promptSeq;
        }
        // An older fluxd sends no request number, so the pane is the match.
        var dialog = dialogWaits.TryGetValue(key, out var wait) && wait.Request is { } number && (p.Int("request") is not { } got || got == number);
        if (window is null && prompt is null && !dialog)
        {
            return;
        }
        var body = p.Body;
        _ = Task.Run(() =>
        {
            if (HerdrWire.Output(body) is { } output)
            {
                Post(() => Show(output, deviceId, window, prompt, dialog));
            }
        });
    }

    void ReceiveSent(Packet p, string deviceId)
    {
        // A newer fluxd sends back the number of the reply. A late answer to
        // an earlier reply then does not end a newer one. An answer without
        // a number matches by the pane, as before.
        if (HerdrWire.Sent(p.Body) is not { } sent)
        {
            return;
        }
        if (sent.Action == "prompt" && Model.FirstTasks.TryGetValue(deviceId, out var task) && task.Phase.State == FirstTaskState.Sending &&
            task.Pane == sent.Pane && (sent.Request is null || sent.Request == task.Reply))
        {
            task.Sent(sent.Error);
            Model.FirstTasks = Model.FirstTasks.SetItem(deviceId, task);
        }
        if (!Model.Replies.TryGetValue(deviceId, out var reply) || reply.Pane != sent.Pane || !reply.Sending ||
            !(sent.Request is null || sent.Request == reply.Seq))
        {
            return;
        }
        Model.Replies = Model.Replies.SetItem(deviceId, reply with
        {
            Sending = false,
            Error = sent.Error,
            Code = sent.Error is null ? null : sent.Code,
        });
        if (sent.Error is not null)
        {
            return;
        }
        Schedule(RereadDelay, () =>
        {
            if (Model.Outputs.TryGetValue(deviceId, out var o) && o.Pane == sent.Pane)
            {
                Read(deviceId, sent.Pane);
            }
            if (Model.Prompts.ContainsKey(HerdrModel.PromptKey(deviceId, sent.Pane)))
            {
                ReadPrompt(deviceId, sent.Pane);
            }
        });
    }

    void ReceiveDone(Packet p, string deviceId)
    {
        if (HerdrWire.Done(p.Body) is not { } done || !Model.Actions.TryGetValue(deviceId, out var action) ||
            action.Action != done.Action || !action.Sending)
        {
            return;
        }
        if (done.Action == "close" && action.Pane != done.Pane)
        {
            return;
        }
        // A late answer to an earlier create or close does not end this one.
        if (done.Request is { } request && request != action.Seq)
        {
            return;
        }
        action = action with { Sending = false, Pane = done.Pane ?? action.Pane, Error = done.Error };
        Model.Actions = Model.Actions.SetItem(deviceId, action);
        SettleFirstTask(deviceId, action);
    }

    // Shows a parsed output on the agent screen and in the prompt of the
    // Inbox. Each place skips it when a newer output came, or when the agent
    // screen shows another pane now. window and prompt are the numbers of
    // the parse for each place, or null when the place did not want it.
    internal void Show(HerdrOutput output, string deviceId, int? window, int? prompt, bool dialog = false)
    {
        lock (gate)
        {
            var key = HerdrModel.PromptKey(deviceId, output.Pane);
            if (window is { } w && parses.GetValueOrDefault(deviceId) == w && Model.Outputs.TryGetValue(deviceId, out var shown) &&
                shown.Pane == output.Pane && AcceptsView(deviceId, output.Pane, output.Request, output.View, output.Path))
            {
                Model.Outputs = Model.Outputs.SetItem(deviceId, output);
                if (output.View != "diff" && output.Error is null)
                {
                    Model.OutputTimes = Model.OutputTimes.SetItem(key, Now());
                }
                AdvanceFirstTask(deviceId);
                // A dialog read that went through the agent screen takes this output.
                if (dialogWaits.TryGetValue(key, out var routed) && routed.Request is null && output.View != "diff")
                {
                    FinishDialog(key, output);
                }
            }
            if (dialog && dialogWaits.TryGetValue(key, out var own) && own.Request is not null)
            {
                FinishDialog(key, output);
            }
            if (prompt is { } n && PromptParses.TryGetValue(key, out var last) && last == n && Model.Prompts.ContainsKey(key))
            {
                Model.Prompts = Model.Prompts.SetItem(key, output);
            }
        }
    }

    // Requests

    bool AcceptsView(string deviceId, string pane, int? request, string view, string path)
    {
        if (!viewReads.TryGetValue(deviceId + ":" + pane, out var expected))
        {
            return true;
        }
        return expected.Accepts(request, view, path, Model.States.GetValueOrDefault(deviceId)?.Review == true);
    }

    // Asks the computer for its agent list now.
    public void Request(string deviceId) => Send(HerdrWire.Request(), deviceId);

    // Asks the computer for the recent output of pane. With review true, the
    // agent screen shows the diff of the folder of the agent, of path or of
    // the whole working tree. With review false, it shows the output again.
    // The output of the last read stays on screen until the answer comes.
    public void Read(string deviceId, string pane, bool? review = null, string path = "")
    {
        lock (gate)
        {
            var key = deviceId + ":" + pane;
            if (review == true)
            {
                reviews[key] = path;
            }
            if (review == false)
            {
                reviews.Remove(key);
            }
            var selected = reviews.TryGetValue(key, out var p) ? p : null;
            var mode = selected is null ? "ansi" : "diff";
            var selectedPath = selected ?? "";
            var token = reads.GetValueOrDefault(deviceId) + 1;
            reads[deviceId] = token;
            viewReads[key] = new HerdrViewRead(token, mode, selectedPath);
            var previous = Model.Output(deviceId, pane);
            var output = previous is not null && previous.View == mode && previous.Path == selectedPath ? previous : new HerdrOutput(pane);
            Model.Outputs = Model.Outputs.SetItem(deviceId, output with { Loading = true, Error = null });
            if (!Send(HerdrWire.ViewRead(pane, mode, selectedPath, token), deviceId))
            {
                Model.Outputs = Model.Outputs.SetItem(deviceId, Model.Outputs[deviceId] with
                {
                    Loading = false,
                    Error = $"{ComputerName(deviceId)} is not reachable",
                });
                return;
            }
            Schedule(ReadTimeout, () =>
            {
                if (reads.GetValueOrDefault(deviceId) != token || Model.Output(deviceId, pane) is not { Loading: true } o)
                {
                    return;
                }
                Model.Outputs = Model.Outputs.SetItem(deviceId, o with { Loading = false, Error = $"{ComputerName(deviceId)} did not answer" });
            });
        }
    }

    // Reads the output of pane again, unless the last read did not end. The
    // polls of the screens use it, so that reads do not pile up on a slow
    // link. A manual refresh uses Read.
    public void Poll(string deviceId, string pane)
    {
        lock (gate)
        {
            if (Model.Output(deviceId, pane)?.Loading == true)
            {
                return;
            }
            Read(deviceId, pane);
        }
    }

    // Forgets the output and the last reply when the agent screen stops showing the agent.
    public void CloseOutput(string deviceId, string pane)
    {
        lock (gate)
        {
            reviews.Remove(deviceId + ":" + pane);
            viewReads.Remove(deviceId + ":" + pane);
            Model.OutputTimes = Model.OutputTimes.Remove(HerdrModel.PromptKey(deviceId, pane));
            if (Model.Outputs.TryGetValue(deviceId, out var o) && o.Pane == pane)
            {
                Model.Outputs = Model.Outputs.Remove(deviceId);
            }
            if (Model.Replies.TryGetValue(deviceId, out var r) && r.Pane == pane)
            {
                Model.Replies = Model.Replies.Remove(deviceId);
            }
        }
    }

    // Shows the agent in pane on the agent screen of a computer. The screen
    // reads the output at once, and again when the status of the agent
    // changes, when the computer connects, and every 5 seconds while the
    // agent works. With review, the screen shows the diff of the folder of
    // the agent. A second call with the same pane and review changes
    // nothing. The agent screen of the Mac app reads in the same way.
    public void Watch(string deviceId, string pane, bool review = false)
    {
        lock (gate)
        {
            if (watches.TryGetValue(deviceId, out var w) && w.Pane == pane && w.Review == review)
            {
                return;
            }
            if (w is not null)
            {
                w.CancelPoll?.Invoke();
                if (w.Pane != pane)
                {
                    CloseOutput(deviceId, w.Pane);
                }
            }
            watches[deviceId] = new Watcher(pane, review);
            RefreshWatch(deviceId);
        }
    }

    // Ends Watch when the agent screen stops showing the agent. It forgets
    // the output and the last reply, see CloseOutput.
    public void Unwatch(string deviceId, string pane)
    {
        lock (gate)
        {
            if (watches.TryGetValue(deviceId, out var w) && w.Pane == pane)
            {
                w.CancelPoll?.Invoke();
                watches.Remove(deviceId);
            }
            CloseOutput(deviceId, pane);
        }
    }

    // Reads the output of the watched agent at once, and starts the poll
    // when the agent works. A computer without a link and an agent that is
    // gone get no read.
    void RefreshWatch(string deviceId)
    {
        if (!watches.TryGetValue(deviceId, out var w))
        {
            return;
        }
        w.CancelPoll?.Invoke();
        w.CancelPoll = null;
        var agent = Model.States.GetValueOrDefault(deviceId)?.Agent(w.Pane);
        w.Status = agent?.Status;
        if (agent is null || !IsOnline(deviceId))
        {
            return;
        }
        // A new status reads at once. Only the polls wait for the last read.
        Read(deviceId, w.Pane, w.Review);
        if (agent.Status == AgentStatus.Working)
        {
            SchedulePoll(deviceId, w);
        }
    }

    void SchedulePoll(string deviceId, Watcher w)
    {
        w.CancelPoll = Schedule(WorkingRefresh, () =>
        {
            if (watches.GetValueOrDefault(deviceId) != w ||
                Model.States.GetValueOrDefault(deviceId)?.Agent(w.Pane)?.Status != AgentStatus.Working)
            {
                return;
            }
            Poll(deviceId, w.Pane);
            SchedulePoll(deviceId, w);
        });
    }

    // Asks the computer for the output of pane for the Inbox. The answer
    // goes to HerdrModel.Prompts. The old lines stay until it comes.
    public void ReadPrompt(string deviceId, string pane)
    {
        lock (gate)
        {
            var key = HerdrModel.PromptKey(deviceId, pane);
            var output = Model.Prompts.GetValueOrDefault(key) ?? new HerdrOutput(pane);
            Model.Prompts = Model.Prompts.SetItem(key, output with { Loading = true, Error = null });
            if (!Send(HerdrWire.Read(pane), deviceId))
            {
                Model.Prompts = Model.Prompts.SetItem(key, Model.Prompts[key] with
                {
                    Loading = false,
                    Error = $"{ComputerName(deviceId)} is not reachable",
                });
                return;
            }
            promptSeq++;
            var token = promptSeq;
            promptReads[key] = token;
            Schedule(ReadTimeout, () =>
            {
                if (promptReads.GetValueOrDefault(key) != token || Model.Prompts.GetValueOrDefault(key) is not { Loading: true } o)
                {
                    return;
                }
                Model.Prompts = Model.Prompts.SetItem(key, o with { Loading = false, Error = $"{ComputerName(deviceId)} did not answer" });
            });
        }
    }

    // Drops each prompt whose key is not in keys. The app calls it when the
    // Inbox items change, with the HerdrModel.PromptKey of each agent that
    // waits.
    public void KeepPrompts(IEnumerable<string> keys)
    {
        lock (gate)
        {
            var keep = keys.ToHashSet();
            foreach (var key in Model.Prompts.Keys.Where(k => !keep.Contains(k)).ToArray())
            {
                Model.Prompts = Model.Prompts.Remove(key);
                promptReads.Remove(key);
                PromptParses.Remove(key);
            }
        }
    }

    // Sends key presses to the agent in pane, for example "2" to select the
    // second choice of a dialog. Only the keys that fluxd allows go out.
    public void SendKeys(string deviceId, string pane, IReadOnlyCollection<string> keys)
    {
        lock (gate)
        {
            if (!HerdrWire.Allowed(keys))
            {
                return;
            }
            SendReply(deviceId, pane, "keys", HerdrWire.Keys(pane, keys));
        }
    }

    // Sends text to the agent in pane. The computer submits it as a prompt.
    // fluxd refuses a prompt to an agent that waits for a choice, with the
    // error "The agent waits for a choice. Pick a choice first." and the
    // code "blocked", see HerdrReply.Blocked. With answer, fluxd types the
    // text into the dialog. Set answer only from an action where the user
    // chose to type an answer. Without feedback, an open review of the pane
    // adds no "Review feedback" line.
    public void SendPrompt(string deviceId, string pane, string text, bool answer = false, bool feedback = true)
    {
        lock (gate)
        {
            var t = text.Trim();
            if (t.Length == 0)
            {
                return;
            }
            if (!answer && feedback && reviews.TryGetValue(deviceId + ":" + pane, out var path))
            {
                t = $"Review feedback for {(path.Length == 0 ? "the working tree" : path)}:\n" + t;
            }
            if (Encoding.UTF8.GetByteCount(t) > HerdrWire.MaxPrompt)
            {
                replies++;
                Model.Replies = Model.Replies.SetItem(deviceId,
                    new HerdrReply(pane, "prompt", replies, Sending: false, Error: "The text is too long. The limit is 16 KB."));
                return;
            }
            SendReply(deviceId, pane, "prompt", HerdrWire.Prompt(pane, t, answer), t);
        }
    }

    // Rejects the action that the agent in pane asks for with the choice
    // keys, such as "No, and tell Codex what to do differently", and then
    // sends text as the next prompt. The prompt goes out when the agent no
    // longer waits for a choice, or after TellWait. fluxd refuses a prompt
    // to an agent that still waits, so the text cannot select a choice.
    public void Tell(string deviceId, string pane, IReadOnlyCollection<string> keys, string text)
    {
        lock (gate)
        {
            SendKeys(deviceId, pane, keys);
            TellLater(deviceId, pane, text, 1);
        }
    }

    void TellLater(string deviceId, string pane, string text, int step)
    {
        Schedule(TellStep, () =>
        {
            var status = Model.States.GetValueOrDefault(deviceId)?.Agents.FirstOrDefault(a => a.Pane == pane)?.Status;
            if (status == AgentStatus.Blocked && TellStep * step < TellWait)
            {
                TellLater(deviceId, pane, text, step + 1);
                return;
            }
            // The reply answers the agent, not a review of its changes.
            SendPrompt(deviceId, pane, text, feedback: false);
        });
    }

    // Types text in the terminal pane, then sends keys, for example "ls"
    // and "enter". Only the keys that fluxd allows go out.
    public void SendInput(string deviceId, string pane, string text, IReadOnlyCollection<string> keys)
    {
        lock (gate)
        {
            if (!HerdrWire.AllowedInput(text, keys))
            {
                return;
            }
            if (Encoding.UTF8.GetByteCount(text) > HerdrWire.MaxPrompt)
            {
                replies++;
                Model.Replies = Model.Replies.SetItem(deviceId,
                    new HerdrReply(pane, "input", replies, Sending: false, Error: "The text is too long. The limit is 16 KB."));
                return;
            }
            SendReply(deviceId, pane, "input", HerdrWire.Input(pane, text, keys));
        }
    }

    // Asks the computer to open a pane: an agent of kind when what is
    // "agent", or a shell when it is "terminal". The pane opens in cwd, as a
    // new tab of workspace, or in a new workspace when workspace is empty. A
    // new workspace opens in the herdr session session, see
    // HerdrModel.CreateSession. Model.Actions has the answer. A new agent
    // gets task as its first prompt when it is ready, see FirstTask.
    public void Create(string deviceId, string what, string kind, string cwd, string workspace, string? task = null, string session = "")
    {
        lock (gate)
        {
            var text = what == "agent" ? task?.Trim() ?? "" : "";
            // The task belongs to the next action.
            Model.FirstTasks = text.Length > 0
                ? Model.FirstTasks.SetItem(deviceId, new FirstTask(text, actions + 1))
                : Model.FirstTasks.Remove(deviceId);
            StartAction(deviceId, new HerdrAction("create", 0, What: what), CreateTimeout, HerdrWire.Create(what, kind, cwd, workspace, session));
        }
    }

    // Forgets the first task of the last new agent, after the UI showed its end.
    public void ClearFirstTask(string deviceId)
    {
        lock (gate)
        {
            Model.FirstTasks = Model.FirstTasks.Remove(deviceId);
        }
    }

    // Asks the computer to close pane. The agent or the shell in it ends.
    public void Close(string deviceId, string pane)
    {
        lock (gate)
        {
            StartAction(deviceId, new HerdrAction("close", 0, Pane: pane), CloseTimeout, HerdrWire.Close(pane));
        }
    }

    // Forgets the last create or close, after the UI used its answer.
    public void ClearAction(string deviceId, int seq)
    {
        lock (gate)
        {
            if (Model.Actions.TryGetValue(deviceId, out var a) && a.Seq == seq)
            {
                Model.Actions = Model.Actions.Remove(deviceId);
            }
        }
    }

    void StartAction(string deviceId, HerdrAction start, TimeSpan timeout, Packet packet)
    {
        actions++;
        var seq = actions;
        var a = start with { Seq = seq };
        Model.Actions = Model.Actions.SetItem(deviceId, a);
        if (!Send(HerdrWire.Numbered(packet, seq), deviceId))
        {
            a = a with { Sending = false, Error = $"{ComputerName(deviceId)} is not reachable" };
            Model.Actions = Model.Actions.SetItem(deviceId, a);
            SettleFirstTask(deviceId, a);
            return;
        }
        Schedule(timeout, () =>
        {
            if (!Model.Actions.TryGetValue(deviceId, out var current) || current.Seq != seq || !current.Sending)
            {
                return;
            }
            current = current with { Sending = false, Error = $"{ComputerName(deviceId)} did not answer" };
            Model.Actions = Model.Actions.SetItem(deviceId, current);
            SettleFirstTask(deviceId, current);
        });
    }

    // First task

    // Gives the answer to a create to the first task of that create.
    void SettleFirstTask(string deviceId, HerdrAction action)
    {
        if (action.Action != "create" || !Model.FirstTasks.TryGetValue(deviceId, out var task) || task.Action != action.Seq)
        {
            return;
        }
        task.Created(action.Pane, action.Error);
        Model.FirstTasks = Model.FirstTasks.SetItem(deviceId, task);
        AdvanceFirstTask(deviceId);
    }

    // Sends the first task when its agent stayed ready for FirstTask.Hold.
    // The output on screen counts when it is of the new agent, so a dialog
    // there holds the task. When the agent becomes ready, the output is read
    // again, and the task is checked again at the end of the hold, and at
    // the deadline for the pane to appear.
    void AdvanceFirstTask(string deviceId)
    {
        if (!Model.FirstTasks.TryGetValue(deviceId, out var task) || task.Pane is not { } pane)
        {
            return;
        }
        var output = Model.Output(deviceId, pane);
        var before = task.Due;
        var appearBefore = task.AppearDue;
        var go = task.Update(Model.States.GetValueOrDefault(deviceId)?.Agent(pane)?.Status, output is { Choices.Count: > 0 }, Clock());
        Model.FirstTasks = Model.FirstTasks.SetItem(deviceId, task);
        if (task.AppearDue is { } appear && appear != appearBefore)
        {
            // The agent list may never have the pane: check again at the deadline.
            Schedule(TimeSpan.FromSeconds(Math.Max(0, appear - Clock()) + 0.05), () => AdvanceFirstTask(deviceId));
        }
        if (task.Due is { } due && due != before)
        {
            if (output is not null)
            {
                Read(deviceId, pane);
            }
            Schedule(TimeSpan.FromSeconds(Math.Max(0, due - Clock()) + 0.05), () => AdvanceFirstTask(deviceId));
        }
        if (!go)
        {
            return;
        }
        task.Reply = SendReply(deviceId, pane, "prompt", HerdrWire.Prompt(pane, task.Text));
        // The reply fails at once when the computer is not reachable.
        if (Model.Replies.TryGetValue(deviceId, out var r) && r.Seq == task.Reply && !r.Sending)
        {
            task.Sent(r.Error);
        }
        Model.FirstTasks = Model.FirstTasks.SetItem(deviceId, task);
    }

    // Sends a reply and returns its number. The packet gets the number, see
    // HerdrWire.Numbered. text is the text of a prompt.
    int SendReply(string deviceId, string pane, string action, Packet packet, string? text = null)
    {
        replies++;
        var seq = replies;
        Model.Replies = Model.Replies.SetItem(deviceId, new HerdrReply(pane, action, seq, Text: text));
        if (!Send(HerdrWire.Numbered(packet, seq), deviceId))
        {
            Model.Replies = Model.Replies.SetItem(deviceId,
                new HerdrReply(pane, action, seq, Sending: false, Error: $"{ComputerName(deviceId)} is not reachable", Text: text));
            return seq;
        }
        Schedule(ReplyTimeout, () =>
        {
            var error = $"{ComputerName(deviceId)} did not answer";
            if (Model.FirstTasks.TryGetValue(deviceId, out var task) && task.Reply == seq && task.Phase.State == FirstTaskState.Sending)
            {
                task.Sent(error);
                Model.FirstTasks = Model.FirstTasks.SetItem(deviceId, task);
            }
            if (Model.Replies.TryGetValue(deviceId, out var r) && r.Seq == seq && r.Sending)
            {
                Model.Replies = Model.Replies.SetItem(deviceId, r with { Sending = false, Error = error });
            }
        });
        return seq;
    }

    string ComputerName(string deviceId) => core?.WithDevice(deviceId, d => d.Name) ?? "The computer";

    // Dialogs

    // The last dialog that a read found for pane, or null.
    public AgentDialog? LatestDialog(string deviceId, string pane) =>
        dialogs.GetValueOrDefault(HerdrModel.PromptKey(deviceId, pane));

    // Reads the dialog of pane and calls done with it. done gets null when
    // the read fails, takes more than AgentDialogs.ReadTimeout, or finds no
    // dialog. A second call while a read waits joins that read. When the
    // agent screen shows the pane, the read goes through the screen, so that
    // the screen and the dialog share 1 answer.
    public void PeekDialog(string deviceId, string pane, Action<AgentDialog?> done)
    {
        lock (gate)
        {
            var key = HerdrModel.PromptKey(deviceId, pane);
            if (dialogWaits.TryGetValue(key, out var joined))
            {
                joined.Callbacks.Add(done);
                return;
            }
            var wait = new DialogWait();
            wait.Callbacks.Add(done);
            dialogWaits[key] = wait;
            if (Model.Output(deviceId, pane) is { } shown)
            {
                if (!shown.Loading)
                {
                    Read(deviceId, pane);
                }
                if (Model.Output(deviceId, pane) is { Loading: false, Error: not null })
                {
                    FinishDialog(key, null);
                    return;
                }
            }
            else
            {
                wait.Request = ++dialogSeq;
                if (!Send(HerdrWire.DialogRead(pane, wait.Request.Value), deviceId))
                {
                    FinishDialog(key, null);
                    return;
                }
            }
            Schedule(AgentDialogs.ReadTimeout, () =>
            {
                if (dialogWaits.TryGetValue(key, out var now) && now == wait)
                {
                    FinishDialog(key, null);
                }
            });
        }
    }

    // Ends the dialog read of a pane with its output, or with null.
    void FinishDialog(string key, HerdrOutput? output)
    {
        if (!dialogWaits.Remove(key, out var wait))
        {
            return;
        }
        var dialog = output is null ? null : AgentDialogs.Parse(output, Now());
        if (dialog is not null)
        {
            dialogs[key] = dialog;
        }
        foreach (var callback in wait.Callbacks)
        {
            callback(dialog);
        }
    }

    // Reads the dialog again and calls onSame with the new dialog when its
    // ID is id. Else it calls onChanged with the new dialog, or with null
    // when the read failed. A caller sends only the choice of the new read,
    // because a menu choice needs the arrows from the new selection.
    public void VerifyDialog(string deviceId, string pane, string id, Action<AgentDialog> onSame, Action<AgentDialog?> onChanged) =>
        PeekDialog(deviceId, pane, d =>
        {
            if (d is not null && d.Id == id)
            {
                onSame(d);
            }
            else
            {
                onChanged(d);
            }
        });

    // Notifications

    internal static string NotificationId(string deviceId, string pane) => $"herdr-{deviceId}-{pane}";

    bool ControlOf(string deviceId) => Model.States.GetValueOrDefault(deviceId)?.Control == true;

    // Opens the output of an agent in the app.
    void OpenThread(string deviceId, string pane)
    {
        Model.Reveal(deviceId, pane);
        Model.Open?.Invoke(deviceId, pane);
    }

    // A click on the notification or on 1 of its buttons. A click on the
    // notification opens the thread. A choice or a reply needs the unlock
    // first, and then a new read of the pane. It sends only when the dialog
    // has the same ID as the dialog of the notification. In each other case
    // it sends nothing and opens the thread.
    void OnNotificationAction(string action, IReadOnlyDictionary<string, string> info, string? text)
    {
        if (!info.TryGetValue(DeviceKey, out var deviceId) || !info.TryGetValue(PaneKey, out var pane))
        {
            return;
        }
        var dialogId = info.GetValueOrDefault(DialogKey, "");
        Post(() => Locked(() =>
        {
            var choice = action.StartsWith(ChoiceAction, StringComparison.Ordinal) ? action[ChoiceAction.Length..] : null;
            var reply = action == ReplyAction;
            if (choice is null && !reply)
            {
                OpenThread(deviceId, pane);
                return;
            }
            var typed = (text ?? "").Trim();
            if (!ControlOf(deviceId) || !IsOnline(deviceId) || Unlock is not { } unlock || (reply && typed.Length == 0))
            {
                OpenThread(deviceId, pane);
                return;
            }
            unlock($"answer agents on {ComputerName(deviceId)}", () => Locked(() => Answer(deviceId, pane, dialogId, choice, typed)), _ =>
                Locked(() => OpenThread(deviceId, pane)));
        }));
    }

    // The check after the unlock. A new read must show the same dialog.
    void Answer(string deviceId, string pane, string dialogId, string? choice, string text)
    {
        if (!ControlOf(deviceId) || !IsOnline(deviceId))
        {
            OpenThread(deviceId, pane);
            return;
        }
        VerifyDialog(deviceId, pane, dialogId, same =>
        {
            if (choice is not null)
            {
                if (same.Choices.FirstOrDefault(c => c.Key == choice) is { } c && HerdrWire.Allowed(c.Keys))
                {
                    SendKeys(deviceId, pane, c.Keys);
                    core?.Host.Notifier.Remove(NotificationId(deviceId, pane));
                    return;
                }
            }
            else if (AgentDialogs.ReplyMatches(same, dialogId))
            {
                SendPrompt(deviceId, pane, text, answer: true);
                core?.Host.Notifier.Remove(NotificationId(deviceId, pane));
                return;
            }
            OpenThread(deviceId, pane);
        }, _ => OpenThread(deviceId, pane));
    }

    // The category of the notification of a dialog. It holds the buttons of
    // that dialog, so that each dialog ID has its own category.
    string DialogCategory(AgentNotice notice)
    {
        var category = $"{NotificationCategory}.{notice.DialogId}";
        if (dialogCategories.Add(notice.DialogId))
        {
            var buttons = notice.Actions.Select(a => a.Kind == NoticeKind.Reply
                ? new NotificationAction(ReplyAction, a.Label, TextInput: true)
                : new NotificationAction(ChoiceAction + a.Key, a.Label)).ToArray();
            core?.Host.Notifier.Register(category, buttons, OnNotificationAction);
        }
        return category;
    }

    // Posts and removes the notifications for alerts.
    void Alert(IReadOnlyList<AgentAlert> alerts, string deviceId, string computer)
    {
        foreach (var a in alerts)
        {
            var key = $"{deviceId}|{a.Pane}";
            if (pending.Remove(key, out var cancel))
            {
                cancel();
            }
            switch (a)
            {
                case AgentAlert.Clear clear:
                    core?.Host.Notifier.Remove(NotificationId(deviceId, clear.Pane));
                    dialogs.Remove(HerdrModel.PromptKey(deviceId, clear.Pane));
                    break;
                case AgentAlert.NeedsInput needs:
                    if (Model.InputAlerts)
                    {
                        PostNotification(needs.Agent, deviceId, computer, null);
                        if (ControlOf(deviceId))
                        {
                            ReadForNotification(needs.Agent, deviceId, computer);
                        }
                    }
                    break;
                case AgentAlert.Finished finished:
                    if (!Model.DoneAlerts)
                    {
                        core?.Host.Notifier.Remove(NotificationId(deviceId, finished.Pane));
                        break;
                    }
                    pending[key] = Schedule(FinishHold, () =>
                    {
                        pending.Remove(key);
                        // The agent must still be ready after the hold.
                        if (Model.States.GetValueOrDefault(deviceId)?.Agent(finished.Pane) is { } now && now.Status.Ready() && Model.DoneAlerts)
                        {
                            PostNotification(now, deviceId, computer, null);
                        }
                    });
                    break;
            }
        }
    }

    // Reads the dialog of a blocked agent and posts the notification again
    // with the question and the buttons. When the read fails or takes more
    // than 3 seconds, the first notification stays, with no buttons.
    void ReadForNotification(HerdrAgent agent, string deviceId, string computer)
    {
        PeekDialog(deviceId, agent.Pane, dialog =>
        {
            if (dialog is null || !Model.InputAlerts || !ControlOf(deviceId) ||
                Model.States.GetValueOrDefault(deviceId)?.Agent(agent.Pane) is not { Status: AgentStatus.Blocked } now)
            {
                return;
            }
            PostNotification(now, deviceId, computer, dialog);
        });
    }

    // Shows that an agent needs input or finished. Each pane has 1
    // notification, and a click opens the output of the agent. A system
    // notification has no subtitle, so the name of the computer is the
    // first line of the body, and the text of the agent is the second. A
    // notification of a dialog has 1 button for each choice or a Reply
    // button, see AgentNotice.
    void PostNotification(HerdrAgent agent, string deviceId, string computer, AgentDialog? dialog)
    {
        if (core is null)
        {
            return;
        }
        var notice = AgentNotice.Build(agent, dialog, ControlOf(deviceId));
        var info = new Dictionary<string, string> { [DeviceKey] = deviceId, [PaneKey] = agent.Pane };
        var category = NotificationCategory;
        if (notice.Actions.Count > 0)
        {
            info[DialogKey] = notice.DialogId;
            category = DialogCategory(notice);
        }
        var text = dialog is not null ? notice.BigText : notice.Text;
        core.Host.Notifier.Post(new SystemNotification(
            NotificationId(deviceId, agent.Pane),
            category,
            notice.Title,
            string.Join('\n', new[] { computer, text }.Where(s => s.Length > 0)))
        {
            UserInfo = info,
        });
    }
}
