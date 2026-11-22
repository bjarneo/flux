using System.Text;
using System.Text.Json.Nodes;

namespace FluxKit;

// The status of a herdr agent. Blocked waits for an approval or an answer.
// Idle and Done are both ready for input. The order of the values is the
// sort order of the agent list.
public enum AgentStatus
{
    Blocked,
    Done,
    Working,
    Idle,
    Unknown,
}

public static class AgentStatuses
{
    // Returns the status for a wire value. An unknown value gives Unknown.
    public static AgentStatus FromWire(string? wire) => wire switch
    {
        "blocked" => AgentStatus.Blocked,
        "done" => AgentStatus.Done,
        "working" => AgentStatus.Working,
        "idle" => AgentStatus.Idle,
        _ => AgentStatus.Unknown,
    };

    // The value on the wire.
    public static string Wire(this AgentStatus status) => status switch
    {
        AgentStatus.Blocked => "blocked",
        AgentStatus.Done => "done",
        AgentStatus.Working => "working",
        AgentStatus.Idle => "idle",
        _ => "unknown",
    };

    // True when the agent is ready for input.
    public static bool Ready(this AgentStatus status) => status is AgentStatus.Done or AgentStatus.Idle;
}

// One coding agent in a herdr pane on a computer. Pane is the herdr pane ID,
// for example w5:p1. A pane of a named session has the session name before
// its ID, for example omarchy/w5:p1. Session is the name of its herdr session.
public sealed record HerdrAgent(
    string Pane,
    string Agent,
    AgentStatus Status,
    string Title = "",
    string Project = "",
    string Workspace = "",
    string Session = HerdrSession.DefaultName)
{
    public string Id => Pane;
}

// A herdr pane without an agent: a terminal. Title is the terminal title,
// which a shell often sets to the command.
public sealed record HerdrTerminal(
    string Pane,
    string Title = "",
    string Project = "",
    string Workspace = "",
    string Session = HerdrSession.DefaultName)
{
    public string Id => Pane;
}

// A herdr workspace that can get a new tab. Cwd is the folder of its active
// tab on the computer.
public sealed record HerdrWorkspace(string Id, string Label, string Cwd = "", string Session = HerdrSession.DefaultName);

// A herdr session on a computer. The default session is the herdr of the
// computer, and a named session is one that the user started with
// herdr session attach NAME. An older fluxd follows the default session only.
public sealed record HerdrSession(string Name, bool IsDefault = false, bool Running = true)
{
    // The name of the default session on the wire.
    public const string DefaultName = "default";

    public string Id => Name;

    // The name of the session for the UI.
    public string Label => IsDefault ? "Default" : Name;
}

// What a computer reports about herdr. Enabled is false when the computer
// has herdr = false in its config.toml. Running is true when fluxd reaches
// the herdr server. Control is true when the computer accepts replies from
// this device, and new agents. Terminals is true when the computer also
// opens terminals for this device and lists them in Panes. Workspaces and
// Kinds are the places and the agent kinds for a new agent. Review is true
// when the computer sends the diff of the folder of an agent. Bridge names
// the actions of the live terminal, which the Mac app does not use.
//
// A newer fluxd also follows the named herdr sessions. Then Agents, Panes,
// and Workspaces hold the items of all sessions, each with its session, and
// Sessions lists the sessions with the default session first. ScopedTo
// gives the items of 1 session for the agent list. Without sessions from
// fluxd, Sessions has the default session only.
public sealed record HerdrState
{
    public HerdrState(
        bool enabled,
        bool running,
        IEnumerable<HerdrAgent> agents,
        bool control = false,
        bool terminals = false,
        IEnumerable<HerdrTerminal>? panes = null,
        IEnumerable<HerdrWorkspace>? workspaces = null,
        IEnumerable<string>? kinds = null,
        bool review = false,
        IEnumerable<HerdrSession>? sessions = null,
        IEnumerable<string>? bridge = null)
    {
        Enabled = enabled;
        Running = running;
        Agents = ValueList.From(agents);
        Control = control;
        Terminals = terminals;
        Panes = ValueList.From(panes ?? []);
        Workspaces = ValueList.From(workspaces ?? []);
        Kinds = ValueList.From(kinds ?? []);
        Review = review;
        var list = ValueList.From(sessions ?? []);
        Sessions = list.Count == 0 ? ValueList.From([new HerdrSession(HerdrSession.DefaultName, true, running)]) : list;
        Bridge = ValueList.From(bridge ?? []);
    }

    public bool Enabled { get; init; }
    public bool Running { get; init; }
    public ValueList<HerdrAgent> Agents { get; init; }
    public bool Control { get; init; }
    public bool Terminals { get; init; }
    public ValueList<HerdrTerminal> Panes { get; init; }
    public ValueList<HerdrWorkspace> Workspaces { get; init; }
    public ValueList<string> Kinds { get; init; }
    public bool Review { get; init; }
    public ValueList<HerdrSession> Sessions { get; init; }
    public ValueList<string> Bridge { get; init; }

    // The agents with Blocked first, then Done, Working, Idle, and Unknown.
    // The herdr order stays inside a group.
    public IReadOnlyList<HerdrAgent> Sorted => Agents.OrderBy(a => (int)a.Status).ToArray();

    public int Blocked => Agents.Count(a => a.Status == AgentStatus.Blocked);

    public HerdrAgent? Agent(string pane) => Agents.FirstOrDefault(a => a.Pane == pane);

    public HerdrTerminal? Terminal(string pane) => Panes.FirstOrDefault(t => t.Pane == pane);

    // The default session.
    public HerdrSession DefaultSession =>
        Sessions.FirstOrDefault(s => s.IsDefault) ?? Sessions.FirstOrDefault() ?? new HerdrSession(HerdrSession.DefaultName, true, Running);

    // The session to show for the chosen session name: that session while
    // the computer has it, else the default session.
    public HerdrSession Session(string? name) =>
        (name is null ? null : Sessions.FirstOrDefault(s => s.Name == name)) ?? DefaultSession;

    // The agents of the session name that need input.
    public int BlockedCount(string name) => Agents.Count(a => a.Session == name && a.Status == AgentStatus.Blocked);

    // The agents, the terminals, and the workspaces of the session name, or
    // of the default session when the computer has no such session. Running
    // tells whether that session runs.
    public HerdrState ScopedTo(string? name)
    {
        var s = Session(name);
        return this with
        {
            Running = s.Running,
            Agents = ValueList.From(Agents.Where(a => a.Session == s.Name)),
            Panes = ValueList.From(Panes.Where(p => p.Session == s.Name)),
            Workspaces = ValueList.From(Workspaces.Where(w => w.Session == s.Name)),
        };
    }
}

// The recent output of one pane. Lines keep the terminal colors, and Text is
// the same output without styles. Loading is true while a read waits for its
// answer. The old lines stay on screen until the new lines come.
public sealed record HerdrOutput
{
    readonly ValueList<TermLine> lines = ValueList<TermLine>.Empty;

    public HerdrOutput(string pane, bool loading = true, IEnumerable<TermLine>? lines = null, bool truncated = false, string? error = null,
        int? request = null, string view = "ansi", string path = "")
    {
        Pane = pane;
        Loading = loading;
        Lines = ValueList.From(lines ?? []);
        Truncated = truncated;
        Error = error;
        Request = request;
        View = view;
        Path = path;
    }

    public string Pane { get; init; }
    public bool Loading { get; init; }

    public ValueList<TermLine> Lines
    {
        get => lines;
        init
        {
            lines = value;
            var plain = value.Select(l => l.Text).ToArray();
            Text = string.Join("\n", plain);
            var numbered = AgentChoice.Find(plain);
            Choices = ValueList.From(numbered.Count == 0 ? AgentChoice.FindMenu(value) : numbered);
        }
    }

    public bool Truncated { get; init; }
    public string? Error { get; init; }
    public int? Request { get; init; }
    public string View { get; init; }
    public string Path { get; init; }

    // The output without styles.
    public string Text { get; private init; } = "";

    // The choices of the dialog at the end of the output: a numbered dialog,
    // or a menu row, see AgentChoice.FindMenu.
    public ValueList<AgentChoice> Choices { get; private init; } = ValueList<AgentChoice>.Empty;
}

// The read that the agent screen waits for: its number, its view, and the
// path of a review.
internal sealed record HerdrViewRead(int Request, string View, string Path)
{
    public bool Accepts(int? request, string view, string path, bool supportsReview)
    {
        if (request is null)
        {
            return !supportsReview && View == "ansi" && view == "ansi" && path.Length == 0;
        }
        return Request == request && View == view && Path == path;
    }
}

// The last reply to a pane. Action is "keys", "prompt", or "input". Sending
// is true until the computer answers. Seq is different for each reply, so
// the UI sees each answer. Code names Error: "blocked" means that the agent
// waits for a choice and fluxd refused the prompt. The UI can then send
// Text again as an answer. Text is the text of a prompt.
public sealed record HerdrReply(
    string Pane,
    string Action,
    int Seq,
    bool Sending = true,
    string? Error = null,
    string? Code = null,
    string? Text = null)
{
    // True when fluxd refused the prompt because the agent waits for a
    // choice. The text can go again as an answer.
    public bool Blocked => Action == "prompt" && !Sending && Code == HerdrWire.BlockedCode && Text is not null;
}

// The answer of the computer to a reply: {"kind":"sent"}. Error is null on
// success. Code names some errors, see HerdrWire.BlockedCode. Request is the
// number of the reply, which a newer fluxd sends back.
public sealed record HerdrSent(string Pane, string Action, string? Error, string? Code = null, int? Request = null);

// The last new agent, new terminal, or close from this device. Action is
// "create" or "close". Pane is the new or closed pane, and it is null until
// the computer reports it. What is "agent" or "terminal" for a create.
// Sending is true until the computer answers. Seq is different for each
// action, so the UI sees each answer.
public sealed record HerdrAction(
    string Action,
    int Seq,
    bool Sending = true,
    string? Pane = null,
    string What = "",
    string? Error = null);

// The answer of the computer to a create or a close: {"kind":"created"} or
// {"kind":"closed"}. Action is "create" or "close". Request is the number of
// the action, which a newer fluxd sends back.
public sealed record HerdrDone(string Action, string? Pane, string? Error, int? Request = null);

// The flux.herdr messages. docs/herdr.md describes the wire format, and
// internal/core/herdr.go in fluxd is the other side.
public static class HerdrWire
{
    // The key names that fluxd accepts in a keys packet.
    public static readonly IReadOnlySet<string> AllowedKeys = new HashSet<string>(
        new[] { "enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n" }
            .Concat(Enumerable.Range(0, 10).Select(d => d.ToString(System.Globalization.CultureInfo.InvariantCulture))));

    // The key names that fluxd accepts in an input packet for a terminal.
    public static readonly IReadOnlySet<string> TerminalKeys = new HashSet<string>(
        new[] { "enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space" }
            .Concat("abcdefghijklmnopqrstuvwxyz".Select(c => $"ctrl+{c}")));

    // The most keys in 1 keys or input packet.
    public const int MaxKeys = 8;

    // The longest prompt or terminal text, in UTF-8 bytes.
    public const int MaxPrompt = 16 * 1024;

    // The number of lines that a read asks for. fluxd allows 1 to 1000.
    public const int ReadLines = 1000;

    // The code of a sent answer when fluxd refused a prompt because the
    // agent waits for a choice.
    public const string BlockedCode = "blocked";

    // The longest output text that this device parses, in UTF-8 bytes.
    // fluxd sends at most the same.
    public const int MaxText = 1 << 20;

    static Packet Herdr(JsonObject body) => new(PacketType.Herdr, body);

    static JsonArray Strings(IEnumerable<string> items) => new(items.Select(k => (JsonNode?)JsonValue.Create(k)).ToArray());

    // Asks the computer for its agent list. The computer answers with a state.
    public static Packet Request() => Herdr(new JsonObject { ["kind"] = "request" });

    // Asks for the recent output of a pane, with its colors.
    public static Packet Read(string pane) =>
        Herdr(new JsonObject { ["kind"] = "read", ["pane"] = pane, ["lines"] = ReadLines, ["format"] = "ansi" });

    // Asks for the output of a pane for the agent screen: the ANSI output
    // or the review diff in format, with the number request. The answer has
    // the number, the view, and the path again.
    public static Packet ViewRead(string pane, string format, string path, int request) =>
        Herdr(new JsonObject
        {
            ["kind"] = "read", ["pane"] = pane, ["format"] = format, ["path"] = path, ["request"] = request, ["lines"] = ReadLines,
        });

    // Asks for the last lines of a pane to find its dialog, with the number
    // request. The answer has the number again.
    public static Packet DialogRead(string pane, int request) =>
        Herdr(new JsonObject { ["kind"] = "read", ["pane"] = pane, ["lines"] = AgentDialogs.ReadLines, ["format"] = "ansi", ["request"] = request });

    // Sends key presses to the agent in a pane.
    public static Packet Keys(string pane, IEnumerable<string> keys) =>
        Herdr(new JsonObject { ["kind"] = "keys", ["pane"] = pane, ["keys"] = Strings(keys) });

    // Sends text to the agent in a pane. With answer, the text answers a
    // dialog of an agent that waits for a choice. Without it, fluxd refuses
    // the text for such an agent.
    public static Packet Prompt(string pane, string text, bool answer = false)
    {
        var body = new JsonObject { ["kind"] = "prompt", ["pane"] = pane, ["text"] = text };
        if (answer)
        {
            body["answer"] = true;
        }
        return Herdr(body);
    }

    // Types text in the terminal of a pane, then presses keys, for example
    // "ls" and "enter".
    public static Packet Input(string pane, string text, IEnumerable<string> keys) =>
        Herdr(new JsonObject { ["kind"] = "input", ["pane"] = pane, ["text"] = text, ["keys"] = Strings(keys) });

    // Asks the computer to open a pane: an agent of kind agent when what is
    // "agent", or a shell when it is "terminal". The pane opens in cwd,
    // where empty is the home folder, as a new tab of workspace, or in a new
    // workspace when workspace is empty. The new workspace opens in the
    // named herdr session session, or in the default session when session is
    // empty. A workspace ID names its session, so the packet has the
    // session only for a new workspace.
    public static Packet Create(string what, string agent, string cwd, string workspace, string session = "")
    {
        var body = new JsonObject
        {
            ["kind"] = "create", ["what"] = what, ["agent"] = agent, ["cwd"] = cwd.Trim(), ["workspace"] = workspace,
        };
        if (workspace.Length == 0 && session.Length > 0 && session != HerdrSession.DefaultName)
        {
            body["herdr_session"] = session;
        }
        return Herdr(body);
    }

    // Asks the computer to close a pane. The agent or the shell in it ends.
    public static Packet Close(string pane) => Herdr(new JsonObject { ["kind"] = "close", ["pane"] = pane });

    // Adds the number of a reply, a create, or a close to its packet. A
    // newer fluxd sends the number back in its answer, so that a late
    // answer to an earlier request does not end this one.
    public static Packet Numbered(Packet packet, int request)
    {
        var body = (JsonObject)packet.Body.DeepClone();
        body["request"] = request;
        return new Packet(packet.Type, body);
    }

    // True when fluxd accepts the keys in 1 keys packet.
    public static bool Allowed(IReadOnlyCollection<string> keys) =>
        keys.Count is > 0 and <= MaxKeys && keys.All(AllowedKeys.Contains);

    // True when fluxd accepts the text and the keys in 1 input packet for a
    // terminal: 0 to 8 terminal keys, and text or keys.
    public static bool AllowedInput(string text, IReadOnlyCollection<string> keys) =>
        keys.Count <= MaxKeys && keys.All(TerminalKeys.Contains) && !(text.Length == 0 && keys.Count == 0);

    // Parses the body of a state packet. It returns null for a body that is not a state.
    public static HerdrState? State(JsonObject body)
    {
        if (Json.String(body["kind"]) != "state")
        {
            return null;
        }
        var kinds = NonEmpty(body["kinds"]);
        var enabled = Json.Bool(body["enabled"]) ?? true;
        var control = enabled && (Json.Bool(body["control"]) ?? false);
        var terminals = control && (Json.Bool(body["terminals"]) ?? false);
        var running = enabled && (Json.Bool(body["running"]) ?? false);
        var agents = ParseAgents(body["agents"], HerdrSession.DefaultName);
        var panes = ParseTerminals(body["panes"], HerdrSession.DefaultName);
        var workspaces = ParseWorkspaces(body["workspaces"], HerdrSession.DefaultName);
        var sessions = new List<HerdrSession>();
        // A newer fluxd lists each session with its items. The top-level
        // lists then hold the default session again, for an older app.
        var seen = new HashSet<string>();
        var named = new List<(HerdrSession Session, JsonObject Body)>();
        if (body["sessions"] is JsonArray list)
        {
            foreach (var e in list)
            {
                if (e is not JsonObject o || Json.String(o["name"]) is not { Length: > 0 } name || !seen.Add(name))
                {
                    continue;
                }
                named.Add((new HerdrSession(name, Json.Bool(o["default"]) ?? false, enabled && (Json.Bool(o["running"]) ?? false)), o));
            }
        }
        if (named.Any(n => n.Session.IsDefault))
        {
            sessions = named.Select(n => n.Session).ToList();
            agents = named.SelectMany(n => ParseAgents(n.Body["agents"], n.Session.Name)).ToList();
            panes = named.SelectMany(n => ParseTerminals(n.Body["panes"], n.Session.Name)).ToList();
            workspaces = named.SelectMany(n => ParseWorkspaces(n.Body["workspaces"], n.Session.Name)).ToList();
        }
        return new HerdrState(
            enabled,
            running || sessions.Any(s => s.Running),
            agents,
            control,
            terminals,
            terminals ? panes : [],
            control ? workspaces : [],
            control ? kinds : [],
            enabled && (Json.Bool(body["review"]) ?? false),
            sessions.Count == 0 ? [new HerdrSession(HerdrSession.DefaultName, true, running)] : sessions,
            NonEmpty(body["bridge"]));
    }

    // The strings of an array that are not empty.
    static List<string> NonEmpty(JsonNode? node) => Json.Strings(node).Where(s => s.Length > 0).ToList();

    static List<HerdrAgent> ParseAgents(JsonNode? list, string session)
    {
        var output = new List<HerdrAgent>();
        foreach (var o in (list as JsonArray ?? []).OfType<JsonObject>())
        {
            if (Json.String(o["pane"]) is not { Length: > 0 } pane)
            {
                continue;
            }
            var name = Json.String(o["agent"]) ?? "";
            output.Add(new HerdrAgent(
                pane,
                name.Length == 0 ? "agent" : name,
                AgentStatuses.FromWire(Json.String(o["status"])),
                Json.String(o["title"]) ?? "",
                Json.String(o["project"]) ?? "",
                Json.String(o["workspace"]) ?? "",
                session));
        }
        return output;
    }

    static List<HerdrTerminal> ParseTerminals(JsonNode? list, string session)
    {
        var output = new List<HerdrTerminal>();
        foreach (var o in (list as JsonArray ?? []).OfType<JsonObject>())
        {
            if (Json.String(o["pane"]) is not { Length: > 0 } pane)
            {
                continue;
            }
            output.Add(new HerdrTerminal(pane, Json.String(o["title"]) ?? "", Json.String(o["project"]) ?? "", Json.String(o["workspace"]) ?? "", session));
        }
        return output;
    }

    static List<HerdrWorkspace> ParseWorkspaces(JsonNode? list, string session)
    {
        var output = new List<HerdrWorkspace>();
        foreach (var o in (list as JsonArray ?? []).OfType<JsonObject>())
        {
            if (Json.String(o["id"]) is not { Length: > 0 } id)
            {
                continue;
            }
            var label = Json.String(o["label"]) ?? "";
            output.Add(new HerdrWorkspace(id, label.Length == 0 ? id : label, Json.String(o["cwd"]) ?? "", session));
        }
        return output;
    }

    // Parses the body of an output packet. It returns null for a body that is not an output.
    public static HerdrOutput? Output(JsonObject body)
    {
        if (Json.String(body["kind"]) != "output" || Json.String(body["pane"]) is not { Length: > 0 } pane)
        {
            return null;
        }
        var error = Json.String(body["error"]) is { Length: > 0 } e ? e : null;
        var (text, cut) = Tail(Json.String(body["text"]) ?? "", MaxText);
        // An older fluxd sends plain text. It has no escape sequences, so the
        // same parser reads it.
        return new HerdrOutput(
            pane,
            loading: false,
            lines: error is null ? TermText.Lines(text) : [],
            truncated: (Json.Bool(body["truncated"]) ?? false) || cut,
            error: error,
            request: Json.Int(body["request"]),
            view: Json.String(body["view"]) ?? "ansi",
            path: Json.String(body["path"]) ?? "");
    }

    // Keeps the end of the text, at most max UTF-8 bytes, from the start of
    // a line when it can, like tailText in fluxd. It returns true when it cut
    // the text.
    internal static (string Text, bool Cut) Tail(string text, int max)
    {
        // A UTF-16 unit takes at most 3 UTF-8 bytes.
        if (text.Length <= max / 3)
        {
            return (text, false);
        }
        var utf8 = Encoding.UTF8.GetBytes(text);
        if (utf8.Length <= max)
        {
            return (text, false);
        }
        var start = utf8.Length - max;
        var newline = Array.IndexOf(utf8, (byte)'\n', start);
        if (newline >= 0 && newline + 1 < utf8.Length)
        {
            start = newline + 1;
        }
        else
        {
            // Start at the first byte of a character, not at a continuation byte.
            while (start < utf8.Length && (utf8[start] & 0xC0) == 0x80)
            {
                start++;
            }
        }
        return (Encoding.UTF8.GetString(utf8, start, utf8.Length - start), true);
    }

    static string? NonEmptyString(JsonNode? node) => Json.String(node) is { Length: > 0 } s ? s : null;

    // Parses the body of a created or closed packet. It returns null for another body.
    public static HerdrDone? Done(JsonObject body)
    {
        var action = Json.String(body["kind"]) switch
        {
            "created" => "create",
            "closed" => "close",
            _ => null,
        };
        if (action is null)
        {
            return null;
        }
        return new HerdrDone(action, NonEmptyString(body["pane"]), NonEmptyString(body["error"]), Json.Int(body["request"]));
    }

    // Parses the body of a sent packet. It returns null for a body that is not a sent answer.
    public static HerdrSent? Sent(JsonObject body)
    {
        if (Json.String(body["kind"]) != "sent" || Json.String(body["pane"]) is not { Length: > 0 } pane)
        {
            return null;
        }
        return new HerdrSent(pane, Json.String(body["action"]) ?? "", NonEmptyString(body["error"]), NonEmptyString(body["code"]),
            Json.Int(body["request"]));
    }
}

// A notification change for one pane that HerdrTracker finds.
public abstract record AgentAlert
{
    public abstract string Pane { get; }

    // The agent waits for an approval or an answer.
    public sealed record NeedsInput(HerdrAgent Agent) : AgentAlert
    {
        public override string Pane => Agent.Pane;
    }

    // The agent stopped working and is ready for input. This device waits a
    // moment before it posts this.
    public sealed record Finished(HerdrAgent Agent) : AgentAlert
    {
        public override string Pane => Agent.Pane;
    }

    // The notification of the pane is no longer true.
    public sealed record Clear(string PaneId) : AgentAlert
    {
        public override string Pane => PaneId;
    }
}

// Finds the status changes of the agents on one computer. The first state
// after a connection only sets the start values, so it posts nothing.
public sealed class HerdrTracker
{
    readonly Dictionary<string, AgentStatus> last = [];

    // The panes of last in the order that they came.
    readonly List<string> panes = [];
    bool fresh = true;

    // Makes the next state set the start values. Call it when the computer connects.
    public void Restart() => fresh = true;

    // Takes a new agent list and returns the notification changes.
    public IReadOnlyList<AgentAlert> Update(IEnumerable<HerdrAgent> agents)
    {
        var output = new List<AgentAlert>();
        var seen = new HashSet<string>();
        foreach (var a in agents)
        {
            seen.Add(a.Pane);
            var known = last.TryGetValue(a.Pane, out var prev);
            // An unknown status gives no information. The last known status stays.
            if (a.Status == AgentStatus.Unknown)
            {
                continue;
            }
            if (!known)
            {
                panes.Add(a.Pane);
            }
            last[a.Pane] = a.Status;
            if (fresh)
            {
                if (a.Status == AgentStatus.Working)
                {
                    output.Add(new AgentAlert.Clear(a.Pane));
                }
                continue;
            }
            if (known && prev == a.Status)
            {
                continue;
            }
            if (a.Status == AgentStatus.Blocked)
            {
                if (known)
                {
                    output.Add(new AgentAlert.NeedsInput(a));
                }
            }
            else if (a.Status.Ready() && known && prev == AgentStatus.Working)
            {
                output.Add(new AgentAlert.Finished(a));
            }
            else if (known)
            {
                output.Add(new AgentAlert.Clear(a.Pane));
            }
        }
        foreach (var pane in panes.Where(p => !seen.Contains(p)))
        {
            last.Remove(pane);
            output.Add(new AgentAlert.Clear(pane));
        }
        panes.RemoveAll(p => !seen.Contains(p));
        fresh = false;
        return output;
    }
}
