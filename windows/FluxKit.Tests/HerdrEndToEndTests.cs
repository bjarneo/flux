using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// A fake herdr server on a Unix socket with 1 agent in the pane w1:p1. It
// answers the calls of fluxd as herdr 0.9.1 does, and it records them. The
// fake server in internal/herdr/herdr_test.go is the model.
sealed class FakeHerdr : IAsyncDisposable
{
    public const string AnsiText =
        "\u001B[38;2;215;119;87m●\u001B[0m Hello from the fake herdr\n\n" +
        "\u001B[38;5;2m●\u001B[0m Bash(make test)\n" +
        "  ⎿  ok\n";

    public const string PlainText = "● Hello from the fake herdr\n\n● Bash(make test)\n  ⎿  ok\n";

    readonly Socket listener;
    readonly CancellationTokenSource stop = new();
    readonly List<NetworkStream> subscribers = [];
    volatile string status = "idle";
    volatile string? readText;
    volatile bool closed;

    public ConcurrentQueue<(string Method, JsonObject Params)> Calls { get; } = new();

    // The status of the agent in w1:p1.
    public string Status
    {
        get => status;
        set => status = value;
    }

    // The text of each read, or null for the default text. A test sets a
    // dialog here.
    public string? ReadText
    {
        get => readText;
        set => readText = value;
    }

    public FakeHerdr(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(path));
        listener.Listen(16);
        _ = Task.Run(AcceptAsync);
    }

    async Task AcceptAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            Socket socket;
            try
            {
                socket = await listener.AcceptAsync(stop.Token);
            }
            catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                return;
            }
            _ = Task.Run(() => ServeAsync(socket));
        }
    }

    async Task ServeAsync(Socket socket)
    {
        var stream = new NetworkStream(socket, ownsSocket: true);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        try
        {
            while (await reader.ReadLineAsync(stop.Token) is { } line)
            {
                if (JsonNode.Parse(line) is not JsonObject request)
                {
                    continue;
                }
                var method = Json.String(request["method"]) ?? "";
                var parameters = request["params"] as JsonObject ?? [];
                Calls.Enqueue((method, (JsonObject)parameters.DeepClone()));
                Write(stream, Answer(method, parameters));
                if (method == "events.subscribe")
                {
                    lock (subscribers)
                    {
                        subscribers.Add(stream);
                    }
                }
            }
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException)
        {
        }
        finally
        {
            lock (subscribers)
            {
                subscribers.Remove(stream);
            }
            stream.Dispose();
        }
    }

    static void Write(NetworkStream stream, JsonObject message)
    {
        var bytes = Encoding.UTF8.GetBytes(message.ToJsonString() + "\n");
        lock (stream)
        {
            stream.Write(bytes);
        }
    }

    static JsonObject Ok(JsonObject result) => new() { ["id"] = "flux", ["result"] = result };

    static JsonObject Error(string code, string message) =>
        new() { ["id"] = "flux", ["error"] = new JsonObject { ["code"] = code, ["message"] = message } };

    JsonObject Agent() => new()
    {
        ["pane_id"] = "w1:p1", ["workspace_id"] = "w1", ["agent"] = "claude", ["agent_status"] = Status,
        ["cwd"] = "/tmp/fake/flux", ["terminal_title_stripped"] = "Fix the test",
    };

    JsonObject Answer(string method, JsonObject parameters)
    {
        switch (method)
        {
            case "ping":
                return Ok(new JsonObject { ["type"] = "pong", ["version"] = "0.9.1", ["protocol"] = 22 });
            case "session.snapshot":
                return Ok(new JsonObject
                {
                    ["type"] = "session_snapshot",
                    ["snapshot"] = new JsonObject
                    {
                        ["version"] = "0.9.1",
                        ["protocol"] = 22,
                        ["workspaces"] = new JsonArray(new JsonObject
                        {
                            ["workspace_id"] = "w1", ["label"] = "flux", ["number"] = 1, ["active_tab_id"] = "w1:t1",
                        }),
                        ["tabs"] = new JsonArray(new JsonObject { ["tab_id"] = "w1:t1", ["workspace_id"] = "w1", ["label"] = "1", ["number"] = 1 }),
                        ["panes"] = closed ? new JsonArray() : new JsonArray(new JsonObject
                        {
                            ["pane_id"] = "w1:p1", ["workspace_id"] = "w1", ["tab_id"] = "w1:t1", ["cwd"] = "/tmp/fake/flux",
                        }),
                        ["agents"] = closed ? new JsonArray() : new JsonArray(Agent()),
                    },
                });
            case "events.subscribe":
                return Ok(new JsonObject { ["type"] = "subscribed" });
            case "server.agent_manifests":
                return Ok(new JsonObject { ["manifests"] = new JsonArray(new JsonObject { ["agent"] = "claude" }) });
            case "agent.read":
                var text = ReadText ?? (Json.String(parameters["format"]) == "ansi" ? AnsiText : PlainText);
                return Ok(new JsonObject
                {
                    ["type"] = "pane_read",
                    ["read"] = new JsonObject { ["pane_id"] = "w1:p1", ["text"] = text, ["truncated"] = false },
                });
            case "agent.prompt":
                // herdr refuses a prompt to an agent that waits for a choice.
                return Status == "blocked" ? Error("agent_blocked", "the agent waits for an answer") : Ok(new JsonObject { ["type"] = "ok" });
            case "agent.get":
                return Ok(new JsonObject { ["type"] = "agent", ["agent"] = Agent() });
            case "pane.close":
                closed = true;
                return Ok(new JsonObject { ["type"] = "ok" });
            case "agent.send_keys":
            case "pane.send_input":
                return Ok(new JsonObject { ["type"] = "ok" });
            default:
                return Error("unknown_method", $"unknown method {method}");
        }
    }

    // Sends an event to each subscription, as herdr does after a change.
    public void Emit(string name, JsonObject data)
    {
        NetworkStream[] streams;
        lock (subscribers)
        {
            streams = subscribers.ToArray();
        }
        foreach (var s in streams)
        {
            try
            {
                Write(s, new JsonObject { ["event"] = name, ["data"] = data.DeepClone() });
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
            }
        }
    }

    public bool Called(string method, Func<JsonObject, bool> match) => Calls.Any(c => c.Method == method && match(c.Params));

    public ValueTask DisposeAsync()
    {
        stop.Cancel();
        listener.Dispose();
        lock (subscribers)
        {
            foreach (var s in subscribers)
            {
                s.Dispose();
            }
            subscribers.Clear();
        }
        return ValueTask.CompletedTask;
    }
}

// The herdr plugin against a headless fluxd: without a herdr server, and
// with the fake herdr server of FakeHerdr.
public class HerdrEndToEndTests
{
    static LanConfig Lan(Fluxd fluxd, int udpPort, int tcpPort) => new()
    {
        UdpPort = udpPort,
        PeerUdpPort = fluxd.UdpPort,
        FirstTcpPort = tcpPort,
        LastTcpPort = tcpPort + 8,
        LoopbackOnly = true,
    };

    [FluxdFact]
    public async Task AFluxdWithoutHerdrAnswersWithItsState()
    {
        await using var fluxd = await Fluxd.StartAsync(33016, 33020);
        var plugin = new HerdrPlugin();
        using var t = new TestCore(Lan(fluxd, 33031, 33040), [plugin]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        plugin.Request(computer.Id);
        await Wait.UntilAsync(() => plugin.Model.States.ContainsKey(computer.Id), "the herdr state", fluxd);
        var state = plugin.Model.States[computer.Id];
        // herdr = true is the default, and no herdr server runs.
        Assert.True(state.Enabled);
        Assert.False(state.Running);
        // herdr_control is off by default.
        Assert.False(state.Control);
        Assert.False(state.Terminals);
        Assert.True(state.Review);
        Assert.Empty(state.Agents);
        Assert.Empty(state.Bridge);
        Assert.Equal([new HerdrSession("default", true, false)], state.Sessions);

        plugin.Read(computer.Id, "w1:p1");
        await Wait.UntilAsync(() => plugin.Model.Output(computer.Id, "w1:p1") is { Loading: false }, "the answer to the read", fluxd);
        Assert.Equal("No agent runs in w1:p1", plugin.Model.Outputs[computer.Id].Error);
        Assert.Empty(plugin.Model.Outputs[computer.Id].Lines);

        plugin.SendKeys(computer.Id, "w1:p1", ["2"]);
        await Wait.UntilAsync(() => plugin.Model.Reply(computer.Id, "w1:p1") is { Sending: false }, "the answer to the keys", fluxd);
        Assert.Equal("This feature is off for this device", plugin.Model.Replies[computer.Id].Error);

        plugin.Create(computer.Id, "agent", "claude", "~", "", "Run the tests");
        await Wait.UntilAsync(() => plugin.Model.Actions.GetValueOrDefault(computer.Id) is { Sending: false }, "the answer to the create", fluxd);
        Assert.Equal("This feature is off for this device", plugin.Model.Actions[computer.Id].Error);
        // The first task fails with its create.
        Assert.Equal(FirstTaskPhase.Failed("This feature is off for this device"), plugin.Model.FirstTasks[computer.Id].Phase);
    }

    [FluxdFact]
    public async Task ReadsSendsKeysAndPromptsThroughHerdr()
    {
        // A headless fluxd does not follow herdr, so this fluxd runs with
        // its desktop parts. The container has no desktop, so they stay off.
        var root = CoreTests.TempDir();
        await using var herdr = new FakeHerdr(Path.Combine(root, "config", "herdr", "herdr.sock"));
        await using var fluxd = await DesktopFluxd.StartAsync(root, 33116, 33120, "herdr = true\nherdr_control = true\ncheck_updates = false\n");
        var plugin = new HerdrPlugin();
        using var t = new TestCore(new LanConfig
        {
            UdpPort = 33131,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = 33140,
            LastTcpPort = 33148,
            LoopbackOnly = true,
        }, [plugin]);
        var shown = new HerdrNotifications();
        t.Core.Host.Notifier.Backend = shown;
        var computer = await fluxd.PairAsync(t);
        var id = computer.Id;
        plugin.Request(id);
        await fluxd.UntilAsync(() => plugin.Model.States.GetValueOrDefault(id) is { Running: true, Control: true } s && s.Agent("w1:p1") is not null,
            "the agent list");
        var state = plugin.Model.States[id];
        Assert.Equal(new HerdrAgent("w1:p1", "claude", AgentStatus.Idle, "Fix the test", "flux", "flux"), state.Agent("w1:p1"));
        Assert.Equal([new HerdrWorkspace("w1", "flux", "/tmp/fake/flux")], state.Workspaces);
        Assert.Equal([new HerdrSession("default", true, true)], state.Sessions);

        // The agent screen reads the output with its colors.
        plugin.Read(id, "w1:p1");
        await fluxd.UntilAsync(() => plugin.Model.Output(id, "w1:p1") is { Loading: false }, "the output");
        var output = plugin.Model.Outputs[id];
        Assert.Null(output.Error);
        Assert.Equal("ansi", output.View);
        Assert.Equal(1, output.Request);
        Assert.Contains(output.Lines, l => l.Spans.Any(s => s.Style.Fg == TermColor.Rgb(0xD77757)));
        var thread = AgentThread.Parse(output.Lines.Select(l => l.Text).ToArray());
        Assert.Contains(new ThreadBlock.Message("Hello from the fake herdr"), thread.Blocks);
        Assert.Contains(new ThreadBlock.Tool(new ThreadTool("Bash", "make test", ["ok"])), thread.Blocks);
        Assert.True(herdr.Called("agent.read", p => Json.String(p["target"]) == "w1:p1" && Json.String(p["format"]) == "ansi" && Json.Int(p["lines"]) == 1000));

        // The Inbox reads the same agent apart from the agent screen.
        plugin.ReadPrompt(id, "w1:p1");
        await fluxd.UntilAsync(() => plugin.Model.Prompt(id, "w1:p1") is { Loading: false, Lines.Count: > 0 }, "the prompt of the Inbox");
        Assert.Null(plugin.Model.Prompt(id, "w1:p1")!.Error);

        // Keys.
        plugin.SendKeys(id, "w1:p1", ["2"]);
        await fluxd.UntilAsync(() => plugin.Model.Reply(id, "w1:p1") is { Action: "keys", Sending: false }, "the answer to the keys");
        Assert.Null(plugin.Model.Replies[id].Error);
        Assert.True(herdr.Called("agent.send_keys", p => Json.String(p["target"]) == "w1:p1" && Json.Strings(p["keys"]).SequenceEqual(["2"])));

        // A prompt.
        plugin.SendPrompt(id, "w1:p1", " Run the tests ");
        await fluxd.UntilAsync(() => plugin.Model.Reply(id, "w1:p1") is { Action: "prompt", Sending: false }, "the answer to the prompt");
        Assert.Null(plugin.Model.Replies[id].Error);
        Assert.True(herdr.Called("agent.prompt", p => Json.String(p["text"]) == "Run the tests"));

        // The agent waits for a choice: a notification, and fluxd refuses a typed prompt.
        herdr.Status = "blocked";
        herdr.Emit("pane.agent_status_changed", new JsonObject { ["pane_id"] = "w1:p1", ["agent_status"] = "blocked" });
        await fluxd.UntilAsync(() => plugin.Model.States[id].Agent("w1:p1")?.Status == AgentStatus.Blocked, "the blocked agent");
        await fluxd.UntilAsync(() => shown.Shown.Any(n => n.Title == "claude in flux needs input"), "the notification");
        Assert.Equal(computer.Name + "\nFix the test", shown.Shown.First(n => n.Title == "claude in flux needs input").Body);
        var before = plugin.Model.Replies[id].Seq;
        plugin.SendPrompt(id, "w1:p1", "No, use git clean");
        await fluxd.UntilAsync(() => plugin.Model.Reply(id, "w1:p1") is { Sending: false } r && r.Seq > before, "the refused prompt");
        var refused = plugin.Model.Replies[id];
        Assert.True(refused.Blocked);
        Assert.Equal(HerdrWire.BlockedCode, refused.Code);
        Assert.Equal("The agent waits for a choice. Pick a choice first.", refused.Error);

        // The same text as an answer goes into the dialog.
        plugin.SendPrompt(id, "w1:p1", refused.Text!, answer: true);
        await fluxd.UntilAsync(() => plugin.Model.Reply(id, "w1:p1") is { Sending: false } r && r.Seq > refused.Seq, "the answer");
        Assert.Null(plugin.Model.Replies[id].Error);
        Assert.True(herdr.Called("pane.send_input", p => Json.String(p["pane_id"]) == "w1:p1" &&
            Json.String(p["text"]) == "No, use git clean" && Json.Strings(p["keys"]).SequenceEqual(["enter"])));

        // A close ends the agent, and the agent list loses it.
        plugin.Close(id, "w1:p1");
        await fluxd.UntilAsync(() => plugin.Model.Actions.GetValueOrDefault(id) is { Action: "close", Sending: false }, "the close");
        Assert.Null(plugin.Model.Actions[id].Error);
        Assert.True(herdr.Called("pane.close", p => Json.String(p["pane_id"]) == "w1:p1"));
        await fluxd.UntilAsync(() => plugin.Model.States[id].Agents.Count == 0, "the agent list without the agent");
    }
}

public class HerdrNotificationEndToEndTests
{
    const string Dialog = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n";
    const string Changed = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n";

    // AC84 to AC88 against a fluxd and the fake herdr: the notification has
    // 1 button for each choice, a button sends the keys of a new read after
    // the unlock, and a changed question sends nothing and opens the thread.
    [FluxdFact]
    public async Task ANotificationButtonSendsTheChoiceAfterTheUnlockAndANewRead()
    {
        var root = CoreTests.TempDir();
        await using var herdr = new FakeHerdr(Path.Combine(root, "config", "herdr", "herdr.sock")) { ReadText = Dialog };
        await using var fluxd = await DesktopFluxd.StartAsync(root, 33216, 33220, "herdr = true\nherdr_control = true\ncheck_updates = false\n");
        var plugin = new HerdrPlugin();
        using var t = new TestCore(new LanConfig
        {
            UdpPort = 33231,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = 33240,
            LastTcpPort = 33248,
            LoopbackOnly = true,
        }, [plugin]);
        var shown = new ActionNotifications();
        t.Core.Host.Notifier.Backend = shown;
        var opened = new System.Collections.Concurrent.ConcurrentQueue<(string, string)>();
        plugin.Model.Open = (d, p) => opened.Enqueue((d, p));
        var unlocks = 0;
        plugin.Unlock = (_, run, _, _) =>
        {
            unlocks++;
            run();
        };
        var computer = await fluxd.PairAsync(t);
        var id = computer.Id;
        plugin.Request(id);
        await fluxd.UntilAsync(() => plugin.Model.States.GetValueOrDefault(id) is { Running: true, Control: true } s && s.Agent("w1:p1") is not null,
            "the agent list");

        herdr.Status = "blocked";
        herdr.Emit("pane.agent_status_changed", new JsonObject { ["pane_id"] = "w1:p1", ["agent_status"] = "blocked" });
        await fluxd.UntilAsync(() => shown.Shown.Any(n => n.Actions.Count == 3), "the notification with 3 buttons");
        var (notice, actions) = shown.Shown.Last(n => n.Actions.Count == 3);
        Assert.Equal("claude in flux needs input", notice.Title);
        Assert.Equal(["Yes", "Yes, always", "No"], actions.Select(a => a.Title));
        Assert.True(herdr.Called("agent.read", p => Json.String(p["target"]) == "w1:p1" && Json.Int(p["lines"]) == 40));
        Assert.False(herdr.Called("agent.send_keys", _ => true));

        // A tap on a choice reads the pane again and sends the keys of the new read.
        var reads = herdr.Calls.Count(c => c.Method == "agent.read");
        t.Core.Host.Notifier.Activate(notice.Category, actions[1].Id, notice.UserInfo);
        await fluxd.UntilAsync(() => herdr.Called("agent.send_keys", p => Json.Strings(p["keys"]).SequenceEqual(["2"])), "the keys of the choice");
        Assert.Equal(1, unlocks);
        Assert.True(herdr.Calls.Count(c => c.Method == "agent.read") > reads);
        Assert.Empty(opened);

        // The question changes before the next tap: nothing goes out, and the thread opens.
        herdr.ReadText = Changed;
        var sent = herdr.Calls.Count(c => c.Method == "agent.send_keys");
        t.Core.Host.Notifier.Activate(notice.Category, actions[0].Id, notice.UserInfo);
        await fluxd.UntilAsync(() => !opened.IsEmpty, "the thread");
        Assert.Equal((id, "w1:p1"), opened.Single());
        Assert.Equal(sent, herdr.Calls.Count(c => c.Method == "agent.send_keys"));
    }
}

// A fluxd with its desktop parts, in the folders of a test. A headless
// fluxd does not follow herdr, so the herdr test needs this fluxd. The
// container has no D-Bus, no Wayland, and no Avahi, so the desktop parts
// stay off. The fluxd broadcasts only to its own UDP port, which no other
// fluxd uses. Fluxd starts the headless fluxd of the other tests.
sealed class DesktopFluxd : IAsyncDisposable
{
    readonly Process process;
    readonly StringBuilder log = new();
    readonly Dictionary<string, string> env;

    public string Root { get; }
    public int UdpPort { get; }

    DesktopFluxd(string root, int udpPort, Dictionary<string, string> env, Process process)
    {
        Root = root;
        UdpPort = udpPort;
        this.env = env;
        this.process = process;
        process.OutputDataReceived += (_, e) => Append(e.Data);
        process.ErrorDataReceived += (_, e) => Append(e.Data);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    void Append(string? line)
    {
        if (line is null)
        {
            return;
        }
        lock (log)
        {
            log.AppendLine(line);
        }
    }

    public string Log
    {
        get
        {
            lock (log)
            {
                return log.ToString();
            }
        }
    }

    // Writes config.toml and starts fluxd in root.
    public static async Task<DesktopFluxd> StartAsync(string root, int udpPort, int tcpPort, string config)
    {
        var run = Path.Combine(root, "run");
        Directory.CreateDirectory(run);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(run, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        Directory.CreateDirectory(Path.Combine(root, "config", "flux"));
        await File.WriteAllTextAsync(Path.Combine(root, "config", "flux", "config.toml"), config);
        var env = new Dictionary<string, string>
        {
            ["HOME"] = root,
            ["XDG_CONFIG_HOME"] = Path.Combine(root, "config"),
            ["XDG_DATA_HOME"] = Path.Combine(root, "data"),
            ["XDG_CACHE_HOME"] = Path.Combine(root, "cache"),
            ["XDG_RUNTIME_DIR"] = run,
            ["FLUX_SOCKET"] = Path.Combine(run, "flux", "fluxd.sock"),
            ["FLUX_RELEASES_URL"] = "http://127.0.0.1:9/",
        };
        var info = new ProcessStartInfo(Path.Combine(Fluxd.BinDir!, "fluxd"))
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "-udp-port", udpPort.ToString(System.Globalization.CultureInfo.InvariantCulture), "-tcp-port", tcpPort.ToString(System.Globalization.CultureInfo.InvariantCulture) })
        {
            info.ArgumentList.Add(a);
        }
        foreach (var (k, v) in env)
        {
            info.Environment[k] = v;
        }
        foreach (var k in new[] { "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "HERDR_SOCKET_PATH", "INVOCATION_ID" })
        {
            info.Environment.Remove(k);
        }
        var fluxd = new DesktopFluxd(root, udpPort, env, Process.Start(info)!);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!File.Exists(env["FLUX_SOCKET"]))
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"waited for the socket of fluxd\n{fluxd.Log}");
            }
            await Task.Delay(50);
        }
        return fluxd;
    }

    // Runs flux-cli with the arguments and returns its output.
    public async Task<string> CliAsync(params string[] args)
    {
        var info = new ProcessStartInfo(Path.Combine(Fluxd.BinDir!, "flux-cli"))
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var a in args)
        {
            info.ArgumentList.Add(a);
        }
        foreach (var (k, v) in env)
        {
            info.Environment[k] = v;
        }
        using var p = Process.Start(info)!;
        p.StandardInput.Close();
        var output = p.StandardOutput.ReadToEndAsync();
        var error = p.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await p.WaitForExitAsync(timeout.Token);
        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException($"flux-cli {string.Join(' ', args)} failed: {await error}{await output}");
        }
        return await output;
    }

    // Waits for the condition, and adds the log of fluxd to a timeout.
    public async Task UntilAsync(Func<bool> condition, string what)
    {
        try
        {
            await Wait.UntilAsync(condition, what);
        }
        catch (TimeoutException e)
        {
            throw new TimeoutException($"{e.Message}\nfluxd log:\n{Log}", e);
        }
    }

    async Task<string?> PairStateAsync(string id)
    {
        var status = JsonNode.Parse(await CliAsync("status", "--json"))!;
        var device = status["devices"]?.AsArray().OfType<JsonObject>().FirstOrDefault(d => Json.String(d["id"]) == id);
        return Json.String(device?["pairState"]);
    }

    // Starts the core, waits for the link, and pairs from this side, as
    // EndToEndTests.PairFromWindowsAsync does with a headless fluxd.
    public async Task<DeviceSnapshot> PairAsync(TestCore t)
    {
        t.Core.Start();
        await UntilAsync(() => t.Computer is { Online: true }, "the link from fluxd");
        var computer = t.Computer!;
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var key = t.Core.PreviewKey(computer.Id, ts);
        t.Core.Pair(computer.Id, ts);
        try
        {
            await Wait.UntilAsync(async () => await PairStateAsync(t.Core.Local.DeviceId) == "incoming", "the request on fluxd");
        }
        catch (TimeoutException e)
        {
            throw new TimeoutException($"{e.Message}\nfluxd log:\n{Log}", e);
        }
        await CliAsync("accept", t.Core.Local.DeviceId, key);
        await UntilAsync(() => t.Computer is { Paired: true }, "the pairing");
        return t.Computer!;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
        }
        catch (InvalidOperationException)
        {
        }
        process.Dispose();
        try
        {
            Directory.Delete(Root, true);
        }
        catch (IOException)
        {
        }
    }
}
